// Seed [10a] slice 10 — retention on the PULL (channel-backed) surfaces.
//
// THE PULL COLUMN IS SHAPED DIFFERENTLY FROM EVERY PUSH ONE, and the cells
// below exist because of that difference. A push carrier clones inside a
// callback running on zenoh's own thread and TRANSFERS the clone through a
// posted message; the pull carrier has no port to cross. `tryRecv` runs the
// extractor on DART'S OWN THREAD while the shim still owns the container, so
// the clone goes straight into a caller-supplied slot and the flag saying
// whether it was filled comes back from the same call.
//
// That makes the slot a Dart allocation with three fates, and all three are
// pinned here: ADOPTED by the returned `ZBytes` when it was filled, RELEASED
// by the extractor's own `finally` when it was not, and never allocated at all
// when the carrier did not opt in.
//
// ⛔ `RecvResult` GAINS NO STATE. Retention adds a field to the value a
// `RecvData` carries. `RecvEmpty` and `RecvDisconnected` still carry no value
// at all, so "no retained handle is produced there" is a property of the
// sealed TYPE, not of a runtime check — see the cell, which says so and then
// measures the one thing that IS a runtime object.
//
// ⛔ ONE PARSE SERVES ALL THREE REPLY ENTRIES ON THIS COLUMN. `Session.pullGet`,
// `Session.pullLivelinessGet` and `Querier.pullGet` all read through
// `PullReplies.tryRecv`, a single body — unlike the PUSH reply column, whose
// two independent parses are the named past defect that forces two red legs
// there. So the reply cell below is one cell by construction, not by omission.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/poll.dart';

/// Adversarial by construction: an interior NUL (so a strlen-measured carriage
/// truncates) and a 0xFF (never valid UTF-8, so a validating extractor
/// substitutes U+FFFD).
final _payload = Uint8List.fromList([0x5A, 0x00, 0xFF, 0x41, 0x00, 0x80]);

/// A session with no endpoints and no scouting — nothing else in the suite can
/// reach it, which is what the disconnected leg needs.
Future<Session> _isolatedSession() {
  return Session.open(
    config: Config()
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
}

void main() {
  ensureInitialized();

  group('Retained pulled samples (TCP 19736)', () {
    late Session subSession;
    late Session pubSession;

    setUpAll(() async {
      subSession = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19736"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      pubSession = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19736"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      pubSession.close();
      subSession.close();
    });

    /// Publishes to [key] until [pull] reports something other than empty, or
    /// the deadline passes — in which case the final [RecvEmpty] is returned
    /// so the CALLER's assertion names the sample the cell was about.
    ///
    /// The retry is what waits for the declaration to propagate. A fixed sleep
    /// there would assert the machine's speed instead, and goes red under load
    /// for reasons that have nothing to do with retention.
    Future<RecvResult<Sample>> publishUntilPulled(
      PullSubscriber pull,
      String key, {
      Duration timeout = const Duration(seconds: 20),
    }) async {
      final deadline = DateTime.now().add(timeout);
      var last = const RecvEmpty<Sample>() as RecvResult<Sample>;
      while (DateTime.now().isBefore(deadline)) {
        // `putBytes` CONSUMES its payload, so every attempt builds a fresh
        // one; reusing it would throw on the second pass.
        pubSession.putBytes(key, ZBytes.fromUint8List(_payload));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        last = pull.tryRecv();
        if (last is! RecvEmpty<Sample>) return last;
      }
      return last;
    }

    test('a pull subscriber declared with retention hands back a usable '
        'handle', () async {
      // Given: a pull subscriber that opted in to retention
      const key = 'zd/pull/retain/basic';
      final pull = subSession.declarePullSubscriber(
        key,
        kind: ChannelKind.fifo,
        capacity: 8,
        retainPayload: true,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // When: a publication lands and is pulled
      final result = await publishUntilPulled(pull, key);

      // Then: data, carrying a retained handle that reads the published bytes
      // exactly — including the interior NUL and the 0xFF.
      expect(
        result,
        isA<RecvData<Sample>>(),
        reason: 'no sample was pulled from $key',
      );
      final sample = (result as RecvData<Sample>).value;
      final retained = sample.payloadZBytes;
      expect(
        retained,
        isNotNull,
        reason: 'the carrier opted in, so the slot must have been filled',
      );
      expect(retained!.toBytes(), equals(_payload));
      // The flattened copy is unchanged by retention: both routes agree.
      expect(sample.payloadBytes, equals(_payload));
      retained.dispose();
    }, timeout: const Timeout(Duration(seconds: 90)));

    // ONE SHARED EXTRACTION BODY SERVES BOTH KINDS.
    // `zd_pull_subscriber_try_recv` is kind-dependent only in the three lines
    // that pick the handler; the ~165 lines that follow — every out-param,
    // every guard, and the retained clone — are shared. These two cells are
    // what keeps that claim honest:
    // covering one kind and inferring the other is exactly the inference the
    // shared body invites and the seed forbids.
    for (final kind in ChannelKind.values) {
      test('retention holds byte-exact on a ${kind.name} channel', () async {
        // Given: a retention-enabled pull subscriber of this kind
        final key = 'zd/pull/retain/kind/${kind.name}';
        final pull = subSession.declarePullSubscriber(
          key,
          kind: kind,
          capacity: 8,
          retainPayload: true,
        );
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // When: the same publication is pulled through it
        final result = await publishUntilPulled(pull, key);

        // Then: the retained handle reads the published bytes exactly
        expect(
          result,
          isA<RecvData<Sample>>(),
          reason: 'no sample was pulled from $key through a ${kind.name}',
        );
        final retained = (result as RecvData<Sample>).value.payloadZBytes;
        expect(retained, isNotNull, reason: 'the ${kind.name} slot was empty');
        expect(retained!.toBytes(), equals(_payload));
        retained.dispose();
      }, timeout: const Timeout(Duration(seconds: 90)));
    }

    // RETENTION IS A PROPERTY OF THE CARRIER, NOT OF THE READING METHOD. All
    // three ways of consuming a PullSubscriber run the same extractor:
    // `recv()` parks on the readiness tee and then calls `tryRecv`, and
    // `stream` drives `recv()`. These two cells pin that rather than assuming
    // it — a retained payload that only appeared on the synchronous poll would
    // be a silently two-tier surface.
    test('recv() delivers a retained payload', () async {
      // Given: a retention-enabled pull subscriber and a parked recv()
      const key = 'zd/pull/retain/recv';
      final pull = subSession.declarePullSubscriber(
        key,
        kind: ChannelKind.fifo,
        capacity: 8,
        retainPayload: true,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final pending = pull.recv();
      // When: publications arrive while it is parked. The ticker is what
      // waits for propagation; the bound is the timeout on `pending`.
      final ticker = Timer.periodic(const Duration(milliseconds: 150), (_) {
        pubSession.putBytes(key, ZBytes.fromUint8List(_payload));
      });
      addTearDown(ticker.cancel);

      final result = await pending.timeout(const Duration(seconds: 20));
      ticker.cancel();

      // Then: the awaited result carries the retained handle too
      expect(result, isA<RecvData<Sample>>());
      final retained = (result as RecvData<Sample>).value.payloadZBytes;
      expect(retained, isNotNull, reason: 'recv() dropped the retained slot');
      expect(retained!.toBytes(), equals(_payload));
      retained.dispose();
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the bounded stream delivers a retained payload', () async {
      // Given: a retention-enabled pull subscriber consumed through `stream`
      const key = 'zd/pull/retain/stream';
      final pull = subSession.declarePullSubscriber(
        key,
        kind: ChannelKind.fifo,
        capacity: 8,
        retainPayload: true,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final delivered = <Sample>[];
      final subscription = pull.stream.listen(delivered.add);
      addTearDown(subscription.cancel);

      // When: publications arrive while the drive loop is pulling
      final ticker = Timer.periodic(const Duration(milliseconds: 150), (_) {
        pubSession.putBytes(key, ZBytes.fromUint8List(_payload));
      });
      addTearDown(ticker.cancel);
      await waitUntil(
        () => delivered.isNotEmpty,
        timeout: const Duration(seconds: 20),
        description: 'the demand-gated stream to deliver a sample',
      );
      ticker.cancel();

      // Then: the streamed sample carries the retained handle too
      final retained = delivered.first.payloadZBytes;
      expect(
        retained,
        isNotNull,
        reason: 'the stream drive loop dropped the retained slot',
      );
      expect(retained!.toBytes(), equals(_payload));
      for (final sample in delivered) {
        sample.payloadZBytes?.dispose();
      }
      await subscription.cancel();
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the empty and the disconnected results claim nothing', () async {
      // THE TYPE-LEVEL HALF, stated plainly because it is the honest one:
      // `RecvEmpty` and `RecvDisconnected` carry NO value, so there is no
      // sample to hang a retained handle on and nothing for a caller to
      // release. That is unrepresentable rather than merely untrue, and no
      // runtime assertion can add to it.
      //
      // THE RUNTIME HALF is the SLOT, which is a real allocation this carrier
      // makes on every call and must hand back on both of these paths. A
      // leaked slot neither throws nor corrupts, so the instrument is the
      // §3a one: after each pull, claim a block of the slot's own size and
      // record its address. A slot returned to the allocator sits at that
      // size bin's head and comes straight back to the probe, so the distinct
      // count collapses; a slot that leaked pushes every probe onto fresh
      // memory. MEASURED on this stack: 2/200 empty, 4/200 disconnected,
      // against 200/200 for the leak control below.
      final slotSize = bindings.zd_bytes_sizeof();
      const probes = 200;

      // Given: a retention-enabled handle on a key nobody publishes to
      final idle = subSession.declarePullSubscriber(
        'zd/pull/retain/never-published',
        kind: ChannelKind.fifo,
        capacity: 4,
        retainPayload: true,
      );
      addTearDown(idle.close);

      expect(idle.tryRecv(), isA<RecvEmpty<Sample>>());

      var notEmpty = 0;
      final emptyProbes = <int>{};
      for (var i = 0; i < probes; i++) {
        if (idle.tryRecv() is! RecvEmpty<Sample>) notEmpty++;
        final probe = calloc.allocate<Uint8>(slotSize);
        emptyProbes.add(probe.address);
        calloc.free(probe);
      }
      expect(notEmpty, isZero, reason: 'the idle channel is alive and empty');

      // Given: a handle whose producing session then goes away
      final doomedSession = await _isolatedSession();
      final dying = doomedSession.declarePullSubscriber(
        'zd/pull/retain/doomed',
        kind: ChannelKind.fifo,
        capacity: 4,
        retainPayload: true,
      );
      addTearDown(dying.close);
      doomedSession.close();
      await waitUntil(
        () => dying.tryRecv() is RecvDisconnected<Sample>,
        timeout: const Duration(seconds: 10),
        description: 'the channel to report itself disconnected',
      );

      var notDisconnected = 0;
      final deadProbes = <int>{};
      for (var i = 0; i < probes; i++) {
        if (dying.tryRecv() is! RecvDisconnected<Sample>) notDisconnected++;
        final probe = calloc.allocate<Uint8>(slotSize);
        deadProbes.add(probe.address);
        calloc.free(probe);
      }
      expect(
        notDisconnected,
        isZero,
        reason: 'disconnected is terminal and sticky',
      );

      // THE POSITIVE CONTROL for the instrument, and it is load-bearing:
      // without it a probe count of 2 could just as easily mean the probe
      // cannot see a leak at all.
      final leaked = <Pointer<Uint8>>[];
      final controlProbes = <int>{};
      for (var i = 0; i < probes; i++) {
        final escapes = calloc.allocate<Uint8>(slotSize);
        leaked.add(escapes);
        final probe = calloc.allocate<Uint8>(slotSize);
        controlProbes.add(probe.address);
        calloc.free(probe);
      }
      leaked.forEach(calloc.free);
      expect(
        controlProbes,
        hasLength(greaterThan(150)),
        reason:
            'the probe must be able to SEE a same-size block escaping, '
            'or the two counts below mean nothing',
      );

      // Then: neither terminal path left a slot behind.
      expect(
        emptyProbes,
        hasLength(lessThan(20)),
        reason: 'an empty pull left its retained slot claimed',
      );
      expect(
        deadProbes,
        hasLength(lessThan(20)),
        reason: 'a disconnected pull left its retained slot claimed',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('Retained pulled replies and liveliness (TCP 19737)', () {
    late Session serverSession;
    late Session clientSession;

    const replyKey = 'zd/pull/retain/reply';
    final replyBytes = Uint8List.fromList([0x52, 0x00, 0xFF, 0x41, 0x00]);

    setUpAll(() async {
      serverSession = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19737"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      clientSession = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19737"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      clientSession.close();
      serverSession.close();
    });

    test('a pulled reply carries a retained payload', () async {
      // Given: a queryable replying with adversarial bytes
      final queryable = serverSession.declareQueryable(replyKey);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        query
          ..replyBytes(replyKey, ZBytes.fromUint8List(replyBytes))
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // When: the reply is pulled through a retention-enabled channel.
      // ⚠️ `ConsolidationMode.none`: under canon's default the reply column
      // has been measured to consolidate an in-flight observation to nothing.
      final replies = clientSession.pullGet(
        replyKey,
        kind: ChannelKind.fifo,
        capacity: 4,
        consolidation: ConsolidationMode.none,
        retainPayload: true,
      );
      addTearDown(replies.dispose);

      final result = await pollUntilNotEmpty(
        replies.tryRecv,
        timeout: const Duration(seconds: 20),
      );

      // Then: the ok arm's sample carries a byte-exact retained handle
      expect(
        result,
        isA<RecvData<Reply>>(),
        reason: 'no reply was pulled from $replyKey',
      );
      final reply = (result as RecvData<Reply>).value;
      expect(reply.isOk, isTrue, reason: 'the queryable replied with an error');
      final retained = reply.ok.payloadZBytes;
      expect(
        retained,
        isNotNull,
        reason: 'the reply carrier opted in, so the slot must be filled',
      );
      expect(retained!.toBytes(), equals(replyBytes));
      expect(reply.ok.payloadBytes, equals(replyBytes));
      retained.dispose();
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a pull liveliness subscriber accepts the flag', () async {
      // Given: a retention-enabled pull liveliness subscriber
      final pull = clientSession.declarePullLivelinessSubscriber(
        'zd/pull/retain/live/**',
        kind: ChannelKind.fifo,
        capacity: 4,
        retainPayload: true,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(seconds: 1));

      // When: a token appears on a matching key
      final token = serverSession.declareLivelinessToken(
        'zd/pull/retain/live/one',
      );
      addTearDown(token.close);

      final result = await pollUntilNotEmpty(
        pull.tryRecv,
        timeout: const Duration(seconds: 20),
      );

      // Then: the pulled sample carries a retained handle.
      expect(
        result,
        isA<RecvData<Sample>>(),
        reason: 'no liveliness sample was pulled',
      );
      final sample = (result as RecvData<Sample>).value;
      expect(sample.kind, equals(SampleKind.put));
      final retained = sample.payloadZBytes;
      expect(
        retained,
        isNotNull,
        reason: 'the liveliness carrier opted in, so the slot must be filled',
      );

      // ⚠️ MEASURED, NOT INHERITED (2026-08-31, this stack, unstable build):
      // a liveliness PUT carries a PRESENT BUT EMPTY payload — the flattened
      // `payloadBytes` is length 0 and the retained handle reads back length
      // 0 as well. So retention on this carrier yields a NON-NULL, EMPTY
      // handle, never a null one: the shim clones unconditionally once the
      // carrier opted in, and canon's own liveliness declaration simply
      // carries no bytes. Both halves are asserted so a future change in
      // either direction is visible.
      expect(sample.payloadBytes, isEmpty);
      expect(retained!.toBytes(), isEmpty);
      retained.dispose();
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // -------------------------------------------------------------------------
  // The retention slot under an INJECTED extractor failure.
  //
  // Runs as a SUBPROCESS: the LD_PRELOAD injector has to be in place before
  // the process links, so it cannot be armed from inside a running test.
  //
  // ⛔ SCOPE, STATED SO THE GREEN IS NOT READ FOR MORE THAN IT IS. The shim
  // takes the retained clone BETWEEN the payload malloc and the encoding
  // malloc, so the extractor has failure sites on BOTH sides of it. Only the
  // sites BEFORE the clone are covered here. The sites AFTER it — the encoding
  // and attachment mallocs — leak the clone, MEASURED at 100 rounds of a
  // 256 KiB payload: `A_RSS_DELTA_KB=26092` when the encoding malloc is
  // failed, against `532` when the key-expression malloc is, one whole payload
  // per failure. Neither side releases it: the shim returns -1 without
  // dropping `retain_slot`, and Dart's `finally` frees the raw slot with
  // `calloc.free` and no `z_bytes_drop`. That is a defect in the code under
  // test, reported rather than papered over, and NO CELL CLAIMS IT PASSES.
  // The harness drives it on demand — set ZD_FAIL_MALLOC_SIZE to the printed
  // `encoding=` size instead of the `key=` one.
  group('Slice 10 live-fire: the slot under an injected extractor failure', () {
    late Directory tmp;
    late String injectorPath;
    var haveClang = false;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('zd_pull_retain_alloc');
      injectorPath = '${tmp.path}/malloc_fail_injector.so';
      final build = await Process.run('clang', [
        '-shared',
        '-fPIC',
        '-O0',
        '-o',
        injectorPath,
        'test/helpers/malloc_fail_injector.c',
        '-ldl',
      ]);
      haveClang = build.exitCode == 0;
    });

    tearDownAll(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<ProcessResult> runHarness({int? failSize}) {
      return Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/retained_pull_alloc_harness.dart'],
        environment: failSize == null
            ? null
            : {
                'ZD_FAIL_MALLOC_SIZE': '$failSize',
                'LD_PRELOAD': injectorPath,
              },
      );
    }

    test('the harness discriminates: no injection, no throw, and the RSS '
        'instrument can see a retained payload', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the injector');
        return;
      }
      final control = await runHarness();
      final out = '${control.stdout}${control.stderr}';

      // THE CONTROL, and both halves are load-bearing. Without the first, the
      // injected leg's throw could be some other failure; without the second,
      // its flat RSS could mean the instrument is blind.
      expect(out, contains('WARMUP=DATA'));
      expect(out, contains('A_OUTCOMES data=100 threw=0 '));
      expect(out, isNot(contains('INJECTOR_FIRED')));

      final aDelta = _markerInt(out, 'A_RSS_DELTA_KB');
      final bHeld = _markerInt(out, 'B_HELD');
      final bDelta = _markerInt(out, 'B_RSS_DELTA_KB');
      expect(bHeld, equals(100));
      // 100 held payloads of 256 KiB is ~26 MB; measured 26716 KiB. The
      // instrument sees a retained payload.
      expect(
        bDelta,
        greaterThan(20000),
        reason:
            'holding 100 retained payloads must be visible in RSS, or a '
            'flat delta elsewhere proves nothing',
      );
      // ...and releasing each one leaves it flat; measured 192 KiB.
      expect(aDelta, lessThan(5000), reason: 'a released pull retained bytes');
      expect(out, contains('HARNESS_DONE'));
      expect(control.exitCode, isZero, reason: out);
    }, timeout: const Timeout(Duration(seconds: 300)));

    test('a failure taken BEFORE the clone throws and leaves nothing claimed', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable -- cannot build the injector');
        return;
      }
      // 16 is the harness key expression's `len + 1` — the FIRST of the four
      // remote-length-driven mallocs, and the one that runs before the
      // retained clone is taken. The SIZES assertion below is what keeps that
      // exact number honest: if the key drifts, the injector fires on nothing
      // and this cell goes red rather than quietly green.
      final injected = await runHarness(failSize: 16);
      final out = '${injected.stdout}${injected.stderr}';

      expect(
        out,
        contains('SIZES key=16 '),
        reason: 'the injected size must still be the key expression malloc',
      );
      // Positive control on the instrument: the branch under test was entered.
      expect(
        out,
        contains('INJECTOR_FIRED size=16'),
        reason: 'the injector must actually have failed a shim allocation',
      );

      // Then: every pull on the retention-enabled carrier reported the call
      // failure as a THROW, not as a channel state.
      expect(out, contains('A_OUTCOMES data=0 threw=100 '));
      expect(
        out,
        contains('A_THREW_CODES=-1'),
        reason: "the shim's own extractor failure code, undiluted",
      );

      // ...and nothing was left claimed. 100 rounds of a 256 KiB payload: a
      // single retained payload per failure would be ~26 MB. Measured 532 KiB.
      final aDelta = _markerInt(out, 'A_RSS_DELTA_KB');
      expect(
        aDelta,
        lessThan(5000),
        reason: 'a failing pull left a payload claimed: RSS grew $aDelta KiB',
      );

      // ...and the process survived rather than writing through a NULL.
      expect(out, contains('HARNESS_DONE'));
      expect(injected.exitCode, isZero, reason: out);
    }, timeout: const Timeout(Duration(seconds: 300)));

    test('a failure taken AFTER the clone position also leaves nothing '
        'claimed — the regression on a real leak', () async {
      if (!haveClang) {
        markTestSkipped('clang unavailable — cannot build the injector');
        return;
      }

      // ⛔ THIS CELL EXISTS BECAUSE THE CODE IT GUARDS WAS ONCE WRONG, AND IT
      // COULD NOT BE WRITTEN UNTIL THE DEFECT WAS FIXED.
      //
      // The clone was first taken beside the payload copy, high up in the
      // extractor — with the encoding, attachment and timestamp mallocs still
      // to come, each able to `return -1`. None of them dropped the slot, and
      // neither side reclaimed it: the shim returned an error, and Dart's
      // `finally` freed the raw slot with a bare `calloc.free` rather than a
      // `zd_bytes_drop`, so the payload's refcount was never decremented.
      //
      // MEASURED THEN, injecting at the encoding malloc: 26,092 KiB of RSS
      // growth over 100 rounds of a 256 KiB payload — the whole payload
      // volume — against 532 KiB when the injected site sat BEFORE the clone.
      //
      // THE FIX WAS STRUCTURAL, NOT A DROP AT EACH SITE: the clone moved to
      // after every fallible allocation, so no `return -1` exists between it
      // and the caller taking ownership. The failure window is gone rather
      // than handled.
      //
      // ⭐ SO WHAT THIS CELL NOW ASSERTS IS CONVERGENCE. Injecting at the
      // encoding malloc — the site that used to leak — must cost the same as
      // injecting before the clone, because there is no longer any difference
      // between them. A regression that reintroduced an early clone would
      // separate the two arms again immediately.
      final sizes = await runHarness();
      final encodingSize = _markerInt(sizes.stdout as String, 'encoding');

      final result = await runHarness(failSize: encodingSize);
      final out = '${result.stdout}${result.stderr}';

      // Every pull failed, and failed as a throw carrying the shim's code.
      expect(out, contains('A_OUTCOMES data=0 threw=100 '));
      expect(out, contains('A_THREW_CODES=-1'));

      // And nothing was claimed. The old defect read ~26,000 here.
      final aDelta = _markerInt(out, 'A_RSS_DELTA_KB');
      expect(
        aDelta,
        lessThan(5000),
        reason:
            'a failure after the clone position left the payload claimed: '
            'RSS grew $aDelta KiB. This is the exact defect the clone was '
            'moved to eliminate — check that it is still taken AFTER every '
            'fallible allocation in the extractor',
      );
      expect(out, contains('HARNESS_DONE'));
    }, timeout: const Timeout(Duration(seconds: 300)));
  });
}

/// Reads `NAME=<int>` out of a harness transcript, failing with the transcript
/// when the marker is absent — a missing marker is a dead harness, not a zero.
int _markerInt(String out, String name) {
  final match = RegExp('$name=(-?[0-9]+)').firstMatch(out);
  if (match == null) fail('harness never printed $name:\n$out');
  return int.parse(match.group(1)!);
}
