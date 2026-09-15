// Seed #6: the query channel — canon's bounded fifo/ring delivery on
// `declareQueryable`, consumed through a paced pull handle instead of a stream.
//
// The query column's lifecycle is the opposite of the reply column's. A reply
// channel self-terminates at query completion; a query channel lives until the
// queryable is undeclared or its session closes, so `RecvDisconnected` here
// means "the producer is gone", and the handle's release is remote-visible —
// which is why it is `close()` and not `dispose()`.
//
// ⚠️ TWO SESSIONS for every overflow / drain cell, and the hazard runs BOTH
// ways on this surface: a full fifo query channel blocks the pushing side
// inside its own `z_get`, including the existing Stream-path `get()` on the
// same session.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/poll.dart';

void main() {
  Future<(Session, Session)> sessionPair(int port) async {
    final listener = Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final hostSession = await Session.open(config: listener);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final connector = Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final getterSession = await Session.open(config: connector);
    await Future<void>.delayed(const Duration(seconds: 1));
    return (hostSession, getterSession);
  }

  group('Slice 12: fifo query channel, end to end (TCP 19371)', () {
    late Session hostSession;
    late Session getterSession;

    setUpAll(() async {
      (hostSession, getterSession) = await sessionPair(19371);
    });

    tearDownAll(() {
      getterSession.close();
      hostSession.close();
    });

    test(
      'a query arrives through a fifo query channel and can be answered',
      () async {
        const key = 'zenoh/dart/test/s12/fifo/basic';
        final pull = hostSession.declarePullQueryable(
          key,
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(pull.close);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final repliesFuture = getterSession
            .get(key, timeout: const Duration(seconds: 20))
            .toList();

        final result = await pollUntilNotEmpty(pull.tryRecv);
        expect(result, isA<RecvData<Query>>());
        final query = (result as RecvData<Query>).value;
        expect(query.keyExpr, equals(key));
        query
          ..reply(key, 'from-the-channel')
          ..dispose();

        final replies = await repliesFuture.timeout(
          const Duration(seconds: 25),
        );
        expect(replies, hasLength(1));
        expect(replies.single.ok.payload, equals('from-the-channel'));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('an empty query channel reports alive-and-empty', () async {
      final pull = hostSession.declarePullQueryable(
        'zenoh/dart/test/s12/fifo/empty',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(pull.tryRecv(), isA<RecvEmpty<Query>>());
    });

    test(
      'closing the handle undeclares the queryable — remote-visible',
      () async {
        const key = 'zenoh/dart/test/s12/fifo/undeclare';
        final pull = hostSession.declarePullQueryable(
          key,
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // CONTROL FIRST, so the negative below cannot be a route that never
        // worked: while the handle is open a getter reaches it.
        final live = getterSession.get(
          key,
          timeout: const Duration(seconds: 10),
        );
        final liveFuture = live.toList();
        final seen = await pollUntilNotEmpty(pull.tryRecv);
        expect(seen, isA<RecvData<Query>>());
        (seen as RecvData<Query>).value
          ..reply(key, 'alive')
          ..dispose();
        expect(
          await liveFuture.timeout(const Duration(seconds: 15)),
          hasLength(1),
        );

        pull.close();
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final after = await getterSession
            .get(key, timeout: const Duration(seconds: 2))
            .toList()
            .timeout(const Duration(seconds: 10));
        // The release is REMOTE-VISIBLE, which is why the method is close() and
        // not dispose().
        expect(after, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('the handle reports its kind and key expression', () async {
      const key = 'zenoh/dart/test/s12/props';
      final fifo = hostSession.declarePullQueryable(
        key,
        kind: ChannelKind.fifo,
        capacity: 2,
      );
      addTearDown(fifo.close);
      expect(fifo.kind, equals(ChannelKind.fifo));
      expect(fifo.keyExpr, equals(key));

      final ring = hostSession.declarePullQueryable(
        '$key/ring',
        kind: ChannelKind.ring,
        capacity: 2,
      );
      addTearDown(ring.close);
      expect(ring.kind, equals(ChannelKind.ring));
    });

    test('calls after close are a handle-state error', () async {
      final pull = hostSession.declarePullQueryable(
        'zenoh/dart/test/s12/closed',
        kind: ChannelKind.fifo,
        capacity: 2,
      )..close();

      // No new query can be obtained after close. That guard is the reason the
      // drain cells in the next slice use SESSION CLOSE as their trigger: it
      // is the only terminal trigger that leaves the handle alive to be polled.
      expect(pull.tryRecv, throwsA(isA<StateError>()));
    });

    test(
      'a negative capacity is refused before any native declaration',
      () async {
        const key = 'zenoh/dart/test/s12/negative';
        for (final kind in ChannelKind.values) {
          expect(
            () =>
                hostSession.declarePullQueryable(key, kind: kind, capacity: -1),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.name,
                'name',
                equals('capacity'),
              ),
            ),
            reason: 'kind=$kind',
          );
        }

        // NOTHING WAS DECLARED -- the outside view, since the throw alone would
        // not show it. A getter finds no queryable on that key expression.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final replies = await getterSession
            .get(key, timeout: const Duration(seconds: 2))
            .toList()
            .timeout(const Duration(seconds: 10));
        expect(replies, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('MEASUREMENT: reply-after-undeclare and drop-after-session-close', () async {
      // THE GATE'S R-11 AMENDMENT. cpp documents replying to a query after its
      // queryable is undeclared as undefined behaviour, and UB has no safe pin,
      // so no suite cell drives it. This cell inspects an INSTRUMENT instead: a
      // subprocess-isolated probe under MALLOC_PERTURB_, so a use-after-free
      // aborts loudly rather than reading plausible bytes, and so a crash
      // cannot take the suite with it.
      //
      // The disposition is keyed off the observed outcome CLASS: benign (an
      // error rc or a silent drop) leaves the binding's documented
      // drain-and-reply-before-you-close contract standing; a crash or abort
      // stops the slice and escalates, because a reachable process crash
      // from safe-looking Dart earns a guard rather than a doc line.
      //
      // MEASURED 2026-08-19, BOTH ARMS BENIGN:
      //   ARM1_QUERIES=1
      //   ARM1_REPLY=returned-normally  <- silent drop, no error, no crash
      //   ARM2_QUERIES=1
      //   ARM2_FIELDS keyExpr=probe/ub/sessionclose params="" payload=null
      //   ARM2_DISPOSED   <- ResponseFinal through a dead session is clean
      //   ARMS_DONE
      final run = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/probes/probe_reply_after_undeclare.dart'],
        environment: {'MALLOC_PERTURB_': '165'},
      );
      final out = '${run.stdout}${run.stderr}';

      // Reached the end, so the exit code below is a real exit rather than an
      // early death that would pass an exit assertion for the wrong reason.
      expect(out, contains('ARMS_DONE'), reason: out);
      expect(run.exitCode, isZero, reason: out);

      // ARM 1 -- benign: the reply call returns rather than crashing.
      expect(out, contains('ARM1_QUERIES=1'));
      expect(out, contains('ARM1_REPLY=returned-normally'));

      // ARM 2 -- benign: a held query survives its session's close well enough
      // to be read and dropped, which grounds the next slice's teardown.
      expect(out, contains('ARM2_QUERIES=1'));
      expect(out, contains('ARM2_DISPOSED'));

      // No abort signature anywhere.
      expect(out, isNot(contains('Segmentation fault')));
      expect(out, isNot(contains('Aborted')));
      // Generous: the probe is a SUBPROCESS that compiles before it runs, and
      // it deliberately waits out two five-second query timeouts.
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a query carries its payload through the channel', () async {
      const key = 'zenoh/dart/test/s12/payload';
      final pull = hostSession.declarePullQueryable(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final sent = Uint8List.fromList([0x00, 0xff, 0x41]);
      unawaited(
        getterSession
            .get(
              key,
              payload: ZBytes.fromUint8List(sent),
              timeout: const Duration(seconds: 20),
            )
            .toList(),
      );

      final result = await pollUntilNotEmpty(pull.tryRecv);
      expect(result, isA<RecvData<Query>>());
      final query = (result as RecvData<Query>).value;
      expect(query.payloadBytes, equals(sent));
      query.dispose();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
  // -------------------------------------------------------------------------
  // Slice 13: the ring kind, and the per-kind drain contract at the trigger
  // where it is observable.
  //
  // ⚠️ THE TRIGGER IS SESSION CLOSE, NOT `close()`, AND THE SUBSTITUTION IS
  // STATED RATHER THAN SMUGGLED. The query channel has two terminal triggers —
  // undeclaring the queryable, and closing its session — and only the second
  // leaves the handle ALIVE to be polled afterwards. `PullQueryable.close()`
  // releases the handle, and Slice 12 pins `tryRecv()` after it as a
  // `StateError`;
  // the seed's own carve renders cpp's post-undeclare drain window as
  // documented drain-before-close rather than as an exposed window. So the
  // per-kind drain contract is pinned at the trigger under which it can be
  // observed at all, and the `close()` trigger's effect is pinned from the
  // REMOTE side instead (the last cell here).
  //
  // Evidence status, stated: the canon-direct measurements behind these
  // contracts were taken at the UNDECLARE trigger. These cells assert at
  // session close, transferred per the sample column's shipped
  // drain-at-session-close cells — an extrapolation until measured here, which
  // is why they pin as found. The session-close query-drop corner itself is
  // grounded by Slice 12's measurement arm 2.
  group('Slice 13: query channel drain contracts at session close', () {
    /// Runs one drain scenario end to end on its own session pair, because the
    /// producing session has to be CLOSED while the handle lives.
    ///
    /// Returns the queries the handle handed over after the close, and whether
    /// each getter saw a reply.
    Future<({List<String> drained, List<int> replyCounts})> drainAfterClose(
      int port,
      ChannelKind kind, {
      int queries = 2,
      int capacity = 4,
    }) async {
      final (hostSession, getterSession) = await sessionPair(port);
      final key = 'zenoh/dart/test/s13/${kind.name}/$port';

      final pull = hostSession.declarePullQueryable(
        key,
        kind: kind,
        capacity: capacity,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The getters go out and are NOT answered: the handle is never polled
      // while the session lives, so the queries sit in the channel.
      final gets = [
        for (var i = 0; i < queries; i++)
          getterSession.get(key, timeout: const Duration(seconds: 3)).toList(),
      ];
      await Future<void>.delayed(const Duration(seconds: 1));

      // THE TRIGGER: the producing session dies under a live handle.
      hostSession.close();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final drained = <String>[];
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var done = false;
      while (!done && DateTime.now().isBefore(deadline)) {
        switch (pull.tryRecv()) {
          case RecvData(:final value):
            drained.add(value.parameters);
            value.dispose();
          case RecvDisconnected():
            done = true;
          case RecvEmpty():
            await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(done, isTrue, reason: 'the channel must reach its terminal state');

      final replyCounts = <int>[];
      for (final g in gets) {
        replyCounts.add((await g.timeout(const Duration(seconds: 15))).length);
      }

      pull.close();
      getterSession.close();
      return (drained: drained, replyCounts: replyCounts);
    }

    test('a ring query channel delivers and can be answered', () async {
      // THE CONTROL for the zeros below: without it, a ring recovering nothing
      // could just as well mean the ring never delivers anything at all.
      final (hostSession, getterSession) = await sessionPair(19372);
      addTearDown(getterSession.close);
      addTearDown(hostSession.close);

      const key = 'zenoh/dart/test/s13/ring/deliver';
      final pull = hostSession.declarePullQueryable(
        key,
        kind: ChannelKind.ring,
        capacity: 4,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final getDone = getterSession
          .get(key, timeout: const Duration(seconds: 20))
          .toList();
      final result = await pollUntilNotEmpty(pull.tryRecv);
      expect(result, isA<RecvData<Query>>());
      (result as RecvData<Query>).value
        ..reply(key, 'ring-answer')
        ..dispose();

      final replies = await getDone.timeout(const Duration(seconds: 25));
      expect(replies, hasLength(1));
      expect(replies.single.ok.payload, equals('ring-answer'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test(
      'a fifo query channel drains its buffer at session close, in order',
      () async {
        final outcome = await drainAfterClose(19373, ChannelKind.fifo);
        expect(outcome.drained, hasLength(2));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('a ring query channel discards its buffer at session close', () async {
      final outcome = await drainAfterClose(19374, ChannelKind.ring);
      expect(outcome.drained, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the discarded queries are remote-visible as getter timeouts', () async {
      final outcome = await drainAfterClose(19375, ChannelKind.ring);
      // OBSERVED WITHOUT DISCRIMINATING, and the cell says so: the fifo run's
      // getters also go unanswered, because nobody can reply once the producing
      // session has closed. The ring-versus-fifo discrimination lives in the
      // handle-side counts above, not here. What this cell adds is that the
      // discard has a REMOTE consequence at all.
      expect(outcome.replyCounts, everyElement(isZero));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the two kinds are contrasted at the same trigger', () async {
      // The discriminator is the CONTRAST: same volume, same capacity, same
      // trigger, driven once per kind.
      final fifo = await drainAfterClose(19376, ChannelKind.fifo, queries: 3);
      final ring = await drainAfterClose(19377, ChannelKind.ring, queries: 3);
      expect(fifo.drained, hasLength(3));
      expect(ring.drained, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('closing the handle releases the queries it holds, observed remotely', () async {
      // The `close()` trigger, pinned from the side where it IS observable. The
      // handle is never polled after close — Slice 12 pins that as StateError —
      // so what this cell shows is the drain-before-close discipline's
      // consequence for the peer.
      final (hostSession, getterSession) = await sessionPair(19378);
      addTearDown(getterSession.close);
      addTearDown(hostSession.close);

      const key = 'zenoh/dart/test/s13/close/release';
      final pull = hostSession.declarePullQueryable(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final gets = [
        for (var i = 0; i < 2; i++)
          getterSession.get(key, timeout: const Duration(seconds: 3)).toList(),
      ];
      await Future<void>.delayed(const Duration(seconds: 1));

      pull.close();

      for (final g in gets) {
        expect(
          await g.timeout(const Duration(seconds: 15)),
          isEmpty,
          reason: 'a query released with the channel cannot be answered',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('MEASUREMENT: capacity 0 on a query channel, per kind, under polling', () async {
      // The query column's capacity-0 semantics are a DIFFERENT question from
      // the reply column's, because the blocked party differs: across two
      // sessions the getter is never the one blocked, so a rendezvous here
      // meets the hosting session's RX thread rather than a caller.
      //
      // MEASURED 2026-08-19 (probe + verbatim output at
      // test/helpers/probes/probe_query_capacity0.dart):
      //
      //   qcap0 ring: recovered=1 getterReplies=1
      //   qcap0 fifo: recovered=1 getterReplies=1
      //
      // BOTH kinds hand the query over under polling, and the getter gets its
      // reply. Pinned as found — no cross-payload extrapolation from the reply
      // column, where the post-completion picture is different.
      final (hostSession, getterSession) = await sessionPair(19379);
      addTearDown(getterSession.close);
      addTearDown(hostSession.close);

      for (final kind in ChannelKind.values) {
        final key = 'zenoh/dart/test/s13/cap0/${kind.name}';
        final pull = hostSession.declarePullQueryable(
          key,
          kind: kind,
          capacity: 0,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final getDone = getterSession
            .get(key, timeout: const Duration(seconds: 5))
            .toList();

        var recovered = 0;
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (recovered == 0 && DateTime.now().isBefore(deadline)) {
          final r = pull.tryRecv();
          if (r is RecvData<Query>) {
            recovered++;
            r.value
              ..reply(key, 'ack')
              ..dispose();
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        final replies = await getDone.timeout(const Duration(seconds: 20));
        expect(recovered, equals(1), reason: 'kind=$kind');
        expect(replies, hasLength(1), reason: 'kind=$kind');

        // Drain before closing -- a courtesy now, not freeze-avoidance.
        // ⚠️ THE ORIGINAL REASON IS STALE and is corrected rather than
        // deleted: it read "so a rendezvous cannot move the freeze into
        // teardown", which was true when written. close() now drops the query
        // handler before undeclaring, so a parked delivery fails fast and the
        // close returns whether or not this drain ran. See
        // `fifo_close_deadlock_test.dart` (seed [MICRO-fifo-close],
        // 2026-08-25). Found by this unit's inventory, not by the seed --
        // the sample column's twin at `pull_recv_test.dart` was named, this
        // one was not.
        var guard = 0;
        while (pull.tryRecv() is RecvData<Query> && guard++ < 20) {}
        pull.close();
      }
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
  // -------------------------------------------------------------------------
  // Slice 14: value fidelity through the query channel.
  //
  // The oracle is the Stream path: every field `declareQueryable` delivers must
  // be delivered here, none dropped and none invented. Fidelity cells drive the
  // CONTRACT's domain, not today's consumer's, and the unit is the round-trip
  // PAIR — each drives a value in through a real getter and asserts byte-exact
  // equality coming out.
  group('Slice 14: query value fidelity through the channel (TCP 19390)', () {
    late Session hostSession;
    late Session getterSession;

    setUpAll(() async {
      (hostSession, getterSession) = await sessionPair(19390);
    });

    tearDownAll(() {
      getterSession.close();
      hostSession.close();
    });

    /// Issues one get with the given options and returns the [Query] the
    /// channel hands over. The query is answered and disposed by the caller.
    Future<Query> oneQueryVia(
      String key, {
      String? parameters,
      ZBytes? payload,
      ZBytes? attachment,
      Encoding? encoding,
      ReplyKeyExpr? acceptReplies,
    }) async {
      final pull = hostSession.declarePullQueryable(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      unawaited(
        getterSession
            .get(
              key,
              parameters: parameters,
              payload: payload,
              attachment: attachment,
              encoding: encoding,
              acceptReplies: acceptReplies,
              timeout: const Duration(seconds: 20),
            )
            .toList(),
      );

      final result = await pollUntilNotEmpty(pull.tryRecv);
      expect(result, isA<RecvData<Query>>(), reason: 'no query arrived');
      final query = (result as RecvData<Query>).value;
      addTearDown(query.dispose);
      return query;
    }

    test('the query key expression arrives byte-exact', () async {
      const key = 'zenoh/dart/test/s14/keyexpr';
      final query = await oneQueryVia(key);
      expect(query.keyExpr, equals(key));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('the parameters arrive length-carried, interior NUL intact', () async {
      // The slice 2 rebase holding on the PULL receive path as well: this path
      // has its own extraction body, so the property is not inherited.
      const sent = 'a=1\x00b=2';
      final query = await oneQueryVia(
        'zenoh/dart/test/s14/params',
        parameters: sent,
      );
      expect(query.parameters, equals(sent));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a binary, invalid-UTF-8 query payload arrives byte-exact', () async {
      final sent = Uint8List.fromList([0x00, 0xff, 0x10, 0xfe, 0x7f]);
      final query = await oneQueryVia(
        'zenoh/dart/test/s14/payload/binary',
        payload: ZBytes.fromUint8List(sent),
      );
      expect(query.payloadBytes, equals(sent));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a present-but-empty query payload is not an absent one', () async {
      final withEmpty = await oneQueryVia(
        'zenoh/dart/test/s14/payload/empty',
        payload: ZBytes.fromUint8List(Uint8List(0)),
      );
      expect(withEmpty.payloadBytes, isNotNull);
      expect(withEmpty.payloadBytes, isEmpty);

      final withNone = await oneQueryVia('zenoh/dart/test/s14/payload/absent');
      expect(withNone.payloadBytes, isNull);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test(
      'query attachments: empty, binary and absent are each distinct',
      () async {
        final withEmpty = await oneQueryVia(
          'zenoh/dart/test/s14/attach/empty',
          attachment: ZBytes.fromUint8List(Uint8List(0)),
        );
        expect(withEmpty.attachmentBytes, isNotNull);
        expect(withEmpty.attachmentBytes, isEmpty);

        final sent = Uint8List.fromList([0xde, 0x00, 0xad, 0xff]);
        final withBinary = await oneQueryVia(
          'zenoh/dart/test/s14/attach/binary',
          attachment: ZBytes.fromUint8List(sent),
        );
        expect(withBinary.attachmentBytes, equals(sent));

        final withNone = await oneQueryVia('zenoh/dart/test/s14/attach/absent');
        expect(withNone.attachmentBytes, isNull);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'the query encoding arrives, absent distinguished from present',
      () async {
        final withEncoding = await oneQueryVia(
          'zenoh/dart/test/s14/encoding/present',
          payload: ZBytes.fromString('{}'),
          encoding: Encoding.applicationJson,
        );
        expect(
          withEncoding.encoding,
          equals(Encoding.applicationJson.mimeType),
        );

        final withNone = await oneQueryVia(
          'zenoh/dart/test/s14/encoding/absent',
        );
        expect(withNone.encoding, isNull);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('acceptsReplies arrives with the policy the getter chose', () async {
      final anyPolicy = await oneQueryVia(
        'zenoh/dart/test/s14/accepts/any',
        acceptReplies: ReplyKeyExpr.any,
      );
      expect(anyPolicy.acceptsReplies, equals(ReplyKeyExpr.any));

      final defaultPolicy = await oneQueryVia(
        'zenoh/dart/test/s14/accepts/default',
      );
      expect(
        defaultPolicy.acceptsReplies,
        equals(ReplyKeyExpr.matchingQuery),
      );
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
