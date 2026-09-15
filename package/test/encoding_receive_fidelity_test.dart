// The RECEIVE half of seed #10's criterion A: an encoding arrives byte-exact.
//
// WHY A CANON-C PEER AND NOT TWO DART SESSIONS. Our own send path is under
// repair in this same seed. Driving our receive path from our send path would
// let one defect hide the other: if both truncate at the first NUL, a
// round-trip through them agrees perfectly and proves nothing. The peer is a
// canon-C publisher that never touches our shim, so a green here is evidence
// about OUR receive seam specifically. GT-16a measured the other side of the
// same question — canon publisher to canon SUBSCRIBER carries the value intact
// — so the target state is known reachable and the defect is known ours.
//
// EVERY LEG CARRIES ITS NUL-FREE CONTROL, in the same run, on the same path.
// Without it a green proves the path works, not that it is length-faithful.
//
// No control byte is spelled as a literal here or in the peer: the interior NUL
// is BUILT with `String.fromCharCode(0)` and reaches the peer as hex. A raw NUL
// in a tracked file turns it binary to `grep`, which is the review instrument
// every station on this line depends on.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/canon_peer.dart';

/// The interior NUL, built rather than spelled.
final nul = String.fromCharCode(0);

/// GT-1's subject: 20 bytes with the NUL at index 10.
final subjectMime = 'text/plain${nul}AFTER-NUL';

/// GT-1's control: 24 bytes carrying canon's own `;` separator, so the
/// subject's failure mode is a real negative and not a transport artifact.
const controlMime = 'text/plain;charset=utf-8';

/// A 3-byte schema whose middle byte is the interior NUL.
final nulSchema = 'a${nul}b';

void main() {
  group('Encoding receive fidelity — sample push path (TCP 19550)', () {
    late Directory tmp;
    late String peerPath;
    late CanonPeer peer;
    late Session session;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('seed10_encoding_peer_');
      peerPath = await buildCanonPeer(
        'test/helpers/encoding_peer.c',
        tmp,
        'encoding_peer',
      );

      peer = await CanonPeer.start(peerPath, ['tcp/127.0.0.1:19550']);

      final config = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19550"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session = await Session.open(config: config);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() async {
      session.close();
      await peer.kill();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// Declares a subscriber on [key], asks the peer to publish one sample
    /// carrying [mime]/[schema], and returns the first sample that arrives.
    ///
    /// The PUB is retried rather than fired once: the subscriber declaration
    /// has to reach the peer before its put, and how long that takes is the
    /// network's business, not this cell's. Every wait is bounded and fails
    /// with the peer's own stdout quoted.
    Future<Sample> receive(String key, String mime, {String? schema}) async {
      final subscriber = session.declareSubscriber(key);
      addTearDown(subscriber.close);

      final first = subscriber.stream.first;
      final command = 'PUB $key ${mimeSpec(mime)} ${schemaSpec(schema)}';

      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final mark = peer.lines.length;
        peer.send(command);
        final done = await peer.waitForLine('PUB_DONE', from: mark);
        expect(
          done,
          equals('PUB_DONE rc=0'),
          reason: 'the canon peer refused to publish: $done',
        );
        final sample = await first
            .timeout(const Duration(milliseconds: 750))
            .then<Sample?>((s) => s)
            .onError<TimeoutException>((_, _) => null);
        if (sample != null) return sample;
      }
      fail(
        'no sample arrived on "$key" within 20s\n'
        '--- peer stdout ---\n${peer.lines.join('\n')}',
      );
    }

    test(
      'an interior-NUL MIME string from a canon publisher survives',
      () async {
        final sample = await receive('zenoh/dart/s10/recv/nul', subjectMime);

        // Byte-identity is the assertion; the length is stated so a failure
        // reports WHERE it truncated rather than only that it did.
        expect(subjectMime.length, equals(20));
        expect(sample.encoding, equals(subjectMime));
        expect(sample.encoding!.length, equals(20));
        expect(sample.encoding!.codeUnitAt(10), equals(0));
      },
    );

    test('the NUL-free control on the same path in the same run', () async {
      final sample = await receive('zenoh/dart/s10/recv/control', controlMime);

      expect(controlMime.length, equals(24));
      expect(sample.encoding, equals(controlMime));
    });

    test('a schema carrying an interior NUL survives', () async {
      final sample = await receive(
        'zenoh/dart/s10/recv/nul-schema',
        'text/plain',
        schema: nulSchema,
      );

      // "text/plain" (10) + ";" (1) + the 3-byte schema = 14.
      expect(sample.encoding, equals('text/plain;$nulSchema'));
      expect(sample.encoding!.length, equals(14));
      expect(sample.encoding!.codeUnitAt(12), equals(0));
    });

    // The peer harness is the SOLE driver for the receive half in isolation.
    // A toolchain-conditional skip would retire it silently, so the guard is
    // asserted to FAIL rather than skip — with the build recipe in the message,
    // because a failure that does not say how to fix itself costs the next
    // reader the same archaeology.
    test('the peer harness fails loud rather than skipping', () {
      expect(
        () => requireCanonHeaders('/nonexistent/build/tree/include'),
        throwsA(
          isA<TestFailure>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('/nonexistent/build/tree/include'),
              contains('cmake --preset'),
              contains('--target install'),
            ),
          ),
        ),
      );

      // ...and it passes for the real one, so the cell above is not green
      // merely because the guard rejects everything.
      requireCanonHeaders();
    });

    // The companion R-18 lands: the bytes were already in hand at the decode
    // site and were being discarded into a lenient String. This is the exact
    // ground truth the String is only a view of — and its absence is why a
    // truncating encoding channel was invisible to every existing test (GT-19).
    test(
      'encodingBytes is the exact ground truth for the interior-NUL case',
      () async {
        final sample = await receive('zenoh/dart/s10/recv/bytes', subjectMime);

        expect(sample.encodingBytes, isNotNull);
        expect(sample.encodingBytes, equals(utf8.encode(subjectMime)));
        expect(sample.encodingBytes!.length, equals(20));
        expect(sample.encodingBytes![10], equals(0));
      },
    );
  });

  // The other three push postings. They share the sample path's mechanism and
  // NOT its borrow lifetime: the query posting's owned string is declared and
  // dropped inside an `if` block that closes eighteen lines before the post,
  // and today only the malloc'd copy stands between the drop and the read.
  group('Encoding receive fidelity — query and reply push paths (TCP 19551)', () {
    late Directory tmp;
    late CanonPeer peer;
    late Session session;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('seed10_encoding_peer_qr_');
      final peerPath = await buildCanonPeer(
        'test/helpers/encoding_peer.c',
        tmp,
        'encoding_peer',
      );

      peer = await CanonPeer.start(peerPath, ['tcp/127.0.0.1:19551']);

      final config = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19551"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session = await Session.open(config: config);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() async {
      session.close();
      await peer.kill();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// Declares OUR queryable on [key], asks the peer to query it, and returns
    /// the first query that arrives. Retried and bounded, like [receive].
    Future<Query> receiveQuery(
      String key,
      String mime, {
      String? schema,
      bool withPayload = true,
    }) async {
      final queryable = session.declareQueryable(key);
      addTearDown(queryable.close);

      final first = queryable.stream.first;
      final payloadSpec = withPayload ? 'p' : '-';
      final command = 'QUERY $key $mime ${schemaSpec(schema)} $payloadSpec';

      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final mark = peer.lines.length;
        peer.send(command);
        final done = await peer.waitForLine('QUERY_DONE', from: mark);
        expect(done, equals('QUERY_DONE rc=0'), reason: done);
        final query = await first
            .timeout(const Duration(milliseconds: 750))
            .then<Query?>((q) => q)
            .onError<TimeoutException>((_, _) => null);
        if (query != null) {
          addTearDown(query.dispose);
          return query;
        }
      }
      fail(
        'no query arrived on "$key" within 20s\n'
        '--- peer stdout ---\n${peer.lines.join('\n')}',
      );
    }

    /// Declares the PEER's queryable on [key] answering on [arm] with the given
    /// encoding, then collects our own replies to it.
    Future<List<Reply>> replies(
      String key,
      String arm,
      String mime, {
      String? schema,
      bool viaQuerier = false,
    }) async {
      final mark = peer.lines.length;
      peer.send('QUERYABLE $key $arm $mime ${schemaSpec(schema)}');
      final declared = await peer.waitForLine('QUERYABLE_DONE', from: mark);
      expect(declared, equals('QUERYABLE_DONE rc=0'), reason: declared);

      // The declaration has to reach us before our get leaves, so the get is
      // retried rather than fired once. Bounded, and it quotes the peer.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final List<Reply> got;
        if (viaQuerier) {
          final querier = session.declareQuerier(key);
          got = await querier.get().toList().timeout(
            const Duration(seconds: 10),
          );
          querier.close();
        } else {
          got = await session
              .get(key, timeout: const Duration(seconds: 2))
              .toList()
              .timeout(const Duration(seconds: 10));
        }
        if (got.isNotEmpty) return got;
      }
      fail(
        'no reply arrived from "$key" within 20s\n'
        '--- peer stdout ---\n${peer.lines.join('\n')}',
      );
    }

    test("a query's interior-NUL encoding survives", () async {
      final query = await receiveQuery(
        'zenoh/dart/s10/q/nul',
        mimeSpec(subjectMime),
      );

      expect(query.encoding, equals(subjectMime));
      expect(query.encoding!.length, equals(20));
      expect(query.encodingBytes, equals(utf8.encode(subjectMime)));
    });

    test("a reply-ok's interior-NUL encoding survives", () async {
      final got = await replies(
        'zenoh/dart/s10/r/ok-nul',
        'ok',
        mimeSpec(subjectMime),
      );

      expect(got.single.isOk, isTrue);
      expect(got.single.ok.encoding, equals(subjectMime));
      expect(got.single.ok.encodingBytes, equals(utf8.encode(subjectMime)));
    });

    test("a reply-err's interior-NUL encoding survives", () async {
      final got = await replies(
        'zenoh/dart/s10/r/err-nul',
        'err',
        mimeSpec(subjectMime),
      );

      expect(got.single.isOk, isFalse);
      expect(got.single.error.encoding, equals(subjectMime));
      expect(got.single.error.encodingBytes, equals(utf8.encode(subjectMime)));
    });

    // The second Dart decode site of each reply arm. It shares the C posting
    // with Session.get and NOT the Dart code, so a fix applied to one file
    // would leave this one truncating.
    test('the same reply legs through Querier', () async {
      final ok = await replies(
        'zenoh/dart/s10/r/qr-ok',
        'ok',
        mimeSpec(subjectMime),
        viaQuerier: true,
      );
      final err = await replies(
        'zenoh/dart/s10/r/qr-err',
        'err',
        mimeSpec(subjectMime),
        viaQuerier: true,
      );

      expect(ok.single.ok.encoding, equals(subjectMime));
      expect(err.single.error.encoding, equals(subjectMime));
    });

    // Edge cases.

    // GT-16's asymmetry: a Query may genuinely carry no encoding, while a
    // Sample and a Reply always render one. The companion must mirror the view
    // — a byte ground truth that reported '' where the view reports null would
    // be a NULL-vs-empty conflation on the exact surface this seed exists to
    // make faithful.
    //
    // ⚠️ MEASURED CORRECTION to the plan's wording, which said "the peer
    // issuing a query that sets no encoding at all". That condition does NOT
    // produce the absent state: with a payload present and the encoding option
    // left NULL, canon substitutes its own default and the query arrives as
    // 'zenoh/bytes'. What produces absence is a query with NO PAYLOAD — there
    // is then no body to describe. The shipped corpus agrees
    // (`get_queryable_test.dart:1918` drives a get with no payload). Both arms
    // are asserted here, so the boundary is pinned rather than assumed.
    test(
      'a query with no payload reads null, and one with a payload does not',
      () async {
        final absent = await receiveQuery(
          'zenoh/dart/s10/q/absent',
          '-',
          withPayload: false,
        );
        expect(absent.encoding, isNull);
        expect(absent.encodingBytes, isNull);

        final defaulted = await receiveQuery('zenoh/dart/s10/q/defaulted', '-');
        expect(defaulted.encoding, equals('zenoh/bytes'));
        expect(defaulted.encodingBytes, isNotNull);
      },
    );

    test('the NUL-free control on each of the three postings', () async {
      final query = await receiveQuery(
        'zenoh/dart/s10/q/control',
        mimeSpec(controlMime),
      );
      final ok = await replies(
        'zenoh/dart/s10/r/ok-control',
        'ok',
        mimeSpec(controlMime),
      );
      final err = await replies(
        'zenoh/dart/s10/r/err-control',
        'err',
        mimeSpec(controlMime),
      );

      expect(query.encoding, equals(controlMime));
      expect(ok.single.ok.encoding, equals(controlMime));
      expect(err.single.error.encoding, equals(controlMime));
    });

    // The §3a class: the behaviour can be right while the memory is wrong, and
    // only an instrument that changes what a freed block CONTAINS separates
    // them. MALLOC_PERTURB_ is read once at libc startup, so it has to be a
    // subprocess.
    //
    // ⚠️ CALIBRATED, and the measurement CORRECTS the ground this cell was
    // specified on. The plan states that without the poisoning allocator this
    // cell is vacuous. Measured against the injected defect (the owned string
    // dropped inside the `if`, before the post), on glibc, at BOTH a 24-byte
    // and a 4-byte value: it fails in all four arms.
    //
    //   24-byte, no perturb : got "<U+FFFD>I,   <U+FFFD>...Vet=utf-8"
    //   24-byte, perturb    : got " <U+FFFD>a   h<U+FFFD>...et=utf-8"
    //    4-byte, no perturb : got "<U+FFFD><U+FFFD>"
    //    4-byte, perturb    : got "<U+FFFD>"
    //
    // The reason is that glibc writes free-list metadata into the head of the
    // block it just reclaimed, so the value is already corrupt. That is
    // INCIDENTAL, not a contract — a block returned to a different arena, a
    // different allocator, or a longer value whose tail escapes the metadata
    // (visible above: `et=utf-8` survived in the 24-byte arms) can read back
    // intact. So MALLOC_PERTURB_ stays: it makes the catch deterministic by
    // construction rather than by accident. What is corrected is the CLAIM —
    // "vacuous without it" was not measured and is not what this allocator
    // does.
    test("the query posting's borrowed storage outlives the post", () async {
      final run = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/probes/probe_query_encoding_borrow.dart'],
        environment: {'MALLOC_PERTURB_': '165'},
      );
      final out = '${run.stdout}${run.stderr}';

      expect(out, contains('BORROW_OK'), reason: out);
      expect(run.exitCode, isZero, reason: out);
      expect(out, isNot(contains('Segmentation fault')));
      expect(out, isNot(contains('Aborted')));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // The three SYNC extractors. They carry the encoding as a bare `char**` with
  // no length out-param, leaving Dart to walk to the first NUL — the same
  // defect as the push postings, arrived at by a different route, and the one
  // the shipped `_decodeLeniently` helpers implement three times over.
  group('Encoding receive fidelity — the three sync extractors (TCP 19552)', () {
    late Directory tmp;
    late CanonPeer peer;
    late Session session;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('seed10_encoding_peer_pull_');
      final peerPath = await buildCanonPeer(
        'test/helpers/encoding_peer.c',
        tmp,
        'encoding_peer',
      );

      peer = await CanonPeer.start(peerPath, ['tcp/127.0.0.1:19552']);

      final config = Config()
        ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19552"]')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      session = await Session.open(config: config);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() async {
      session.close();
      await peer.kill();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// Polls [tryRecv] until it yields data, re-issuing [command] as it goes.
    ///
    /// `tryRecv` is the surface under test, so the wait is a bounded poll over
    /// it rather than a switch to the blocking `recv()`. Fails with the peer's
    /// stdout quoted; an unbounded wait here would freeze the serial suite.
    Future<T> pollTryRecv<T>(
      RecvResult<T> Function() tryRecv,
      String command,
    ) async {
      // `PUB` and `PUB_EMPTY` both answer PUB_DONE; `QUERY` answers QUERY_DONE.
      final verb = command.split(' ').first;
      final ack = verb == 'QUERY' ? 'QUERY_DONE' : 'PUB_DONE';

      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final mark = peer.lines.length;
        peer.send(command);
        expect(
          await peer.waitForLine(ack, from: mark),
          equals('$ack rc=0'),
          reason: peer.lines.join('\n'),
        );
        for (var i = 0; i < 15; i++) {
          final r = tryRecv();
          if (r is RecvData<T>) return r.value;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      fail(
        'nothing arrived for "$command" within 20s\n'
        '--- peer stdout ---\n${peer.lines.join('\n')}',
      );
    }

    test(
      'PullSubscriber.tryRecv returns an interior-NUL encoding whole',
      () async {
        const key = 'zenoh/dart/s10/pull/sub-nul';
        final pull = session.declarePullSubscriber(key, capacity: 8);
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final sample = await pollTryRecv(
          pull.tryRecv,
          'PUB $key ${mimeSpec(subjectMime)} -',
        );

        expect(sample.encoding, equals(subjectMime));
        expect(sample.encodingBytes, equals(utf8.encode(subjectMime)));
      },
    );

    test(
      'PullQueryable.tryRecv returns an interior-NUL query encoding whole',
      () async {
        const key = 'zenoh/dart/s10/pull/q-nul';
        final pull = session.declarePullQueryable(
          key,
          kind: ChannelKind.fifo,
          capacity: 8,
        );
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final query = await pollTryRecv(
          pull.tryRecv,
          'QUERY $key ${mimeSpec(subjectMime)} - p',
        );
        addTearDown(query.dispose);

        expect(query.encoding, equals(subjectMime));
        expect(query.encodingBytes, equals(utf8.encode(subjectMime)));
      },
    );

    test(
      'PullReplies.tryRecv returns interior-NUL encodings on both arms',
      () async {
        for (final arm in ['ok', 'err']) {
          final key = 'zenoh/dart/s10/pull/r-$arm';
          final mark = peer.lines.length;
          peer.send('QUERYABLE $key $arm ${mimeSpec(subjectMime)} -');
          expect(
            await peer.waitForLine('QUERYABLE_DONE', from: mark),
            equals('QUERYABLE_DONE rc=0'),
          );
          await Future<void>.delayed(const Duration(milliseconds: 500));

          final pull = session.pullGet(
            key,
            kind: ChannelKind.fifo,
            capacity: 8,
            timeout: const Duration(seconds: 3),
          );
          addTearDown(pull.dispose);

          Reply? reply;
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (reply == null && DateTime.now().isBefore(deadline)) {
            final r = pull.tryRecv();
            if (r is RecvData<Reply>) reply = r.value;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(reply, isNotNull, reason: peer.lines.join('\n'));

          final encoding = arm == 'ok'
              ? reply!.ok.encoding
              : reply!.error.encoding;
          expect(encoding, equals(subjectMime), reason: 'arm $arm');
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    // Edge cases.

    // ⭐ THE EXECUTED DRIVER for a cell the shim and seed #5's plan archive both
    // record as verified STRUCTURALLY ONLY. The present-but-empty encoding —
    // rendering as a zero-length string — is unreachable from every public
    // canon construction route (measured, GT-16c: all four render
    // "zenoh/bytes"). `zc_internal_encoding_from_data({65535, NULL, 0})`
    // reaches it, sits at guard depth 0, and so drives this on both variants.
    test('the push and pull surfaces agree on present-but-empty', () async {
      const key = 'zenoh/dart/s10/pull/empty';
      final push = session.declareSubscriber(key);
      addTearDown(push.close);
      final pull = session.declarePullSubscriber(key, capacity: 8);
      addTearDown(pull.close);
      final pushed = push.stream.first;
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final pulled = await pollTryRecv(pull.tryRecv, 'PUB_EMPTY $key');
      final pushedSample = await pushed.timeout(const Duration(seconds: 10));

      // Present but EMPTY on both surfaces — never null on one and '' on the
      // other, which is what the D-7 alignment exists to prevent.
      expect(pulled.encoding, equals(''));
      expect(pushedSample.encoding, equals(''));
      expect(pulled.encodingBytes, isNotNull);
      expect(pulled.encodingBytes, isEmpty);
      expect(pushedSample.encodingBytes, isNotNull);
      expect(pushedSample.encodingBytes, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('absent stays absent on the pull query surface', () async {
      const key = 'zenoh/dart/s10/pull/q-absent';
      final pull = session.declarePullQueryable(
        key,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final query = await pollTryRecv(pull.tryRecv, 'QUERY $key - - -');
      addTearDown(query.dispose);

      // Distinct from the '' of the cell above: null is absent.
      expect(query.encoding, isNull);
      expect(query.encodingBytes, isNull);
    });

    test('the NUL-free control on each of the three extractors', () async {
      const subKey = 'zenoh/dart/s10/pull/sub-control';
      final sub = session.declarePullSubscriber(subKey, capacity: 8);
      addTearDown(sub.close);
      const qKey = 'zenoh/dart/s10/pull/q-control';
      final qable = session.declarePullQueryable(
        qKey,
        kind: ChannelKind.fifo,
        capacity: 8,
      );
      addTearDown(qable.close);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final sample = await pollTryRecv(
        sub.tryRecv,
        'PUB $subKey ${mimeSpec(controlMime)} -',
      );
      final query = await pollTryRecv(
        qable.tryRecv,
        'QUERY $qKey ${mimeSpec(controlMime)} - p',
      );
      addTearDown(query.dispose);

      const replyKey = 'zenoh/dart/s10/pull/r-control';
      final mark = peer.lines.length;
      peer.send('QUERYABLE $replyKey ok ${mimeSpec(controlMime)} -');
      expect(
        await peer.waitForLine('QUERYABLE_DONE', from: mark),
        equals('QUERYABLE_DONE rc=0'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final replies = session.pullGet(
        replyKey,
        kind: ChannelKind.fifo,
        capacity: 8,
        timeout: const Duration(seconds: 3),
      );
      addTearDown(replies.dispose);
      Reply? reply;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (reply == null && DateTime.now().isBefore(deadline)) {
        final r = replies.tryRecv();
        if (r is RecvData<Reply>) reply = r.value;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(sample.encoding, equals(controlMime));
      expect(query.encoding, equals(controlMime));
      expect(reply?.ok.encoding, equals(controlMime));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
