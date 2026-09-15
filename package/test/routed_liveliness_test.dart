@Timeout(Duration(minutes: 5))
library;

// Presence detection -- liveliness -- with a router actually in the path.
//
// This is the largest class in the unit and the one with the widest gap
// between what a cell asserts and where it asserts it. A token's DELETE on a
// holder's disappearance is the observable a deployment depends on, and a
// router's own lifecycle handling is what mediates it -- yet every liveliness
// cell in the default suite certifies it over a DIRECT peer link, the one
// shape a deployment never uses.
//
// Nothing here replaces anything. Every original stays exactly where it is,
// unedited, and keeps certifying the direct path.
//
// THE ORIGINALS, AND THE COUNTERPART CARRYING EACH CLAIM
//
// (Line numbers verified against HEAD. The slice brief cited a set of lines
// that are all 10-18 lower in this file; the TEST NAMES it gave are exact, so
// each row below is keyed by name and carries the measured line.)
//
//   test/liveliness_test.dart:124 "Subscriber receives PUT when token is
//   declared" (assertions at :133-:134)
//     -> "a token declaration crosses the router as a put"
//
//   test/liveliness_test.dart:139 "Subscriber receives DELETE when token is
//   closed" (assertions at :158-:161)
//     -> "closing the token crosses the router as a delete"
//
//   test/liveliness_test.dart:164 "Multiple tokens produce multiple PUT and
//   individual DELETE" (assertions at :195-:201)
//     -> "two tokens produce two puts and two individual deletes"
//
//   test/liveliness_test.dart:456 "history=true receives existing alive
//   tokens as PUT" (assertions at :473-:475)
//     -> "history replays a token already alive through the router"
//
//   test/liveliness_test.dart:478 "history=false does NOT receive existing
//   alive tokens" (assertion at :494)
//     -> "history omitted does not replay a pre-existing token"
//
//   test/liveliness_test.dart:371 "token declare/undeclare delivers PUT then
//   DELETE" (assertions at :387-:389) -- the BACKGROUND carrier
//     -> "the background carrier delivers put then delete through the router"
//
//   test/liveliness_test.dart:392 "history replays a pre-existing token as
//   PUT" (assertions at :404-:405) -- the BACKGROUND carrier
//     -> "the background carrier replays a pre-existing token"
//
//   test/liveliness_test.dart:261 "livelinessGet returns alive token"
//   (assertions at :275-:277)
//     -> "livelinessGet reaches the live token through the router"
//
//   test/liveliness_test.dart:279 "livelinessGet returns empty stream when no
//   tokens alive" (assertion at :289)
//     -> "livelinessGet reports no reply where nothing is alive"
//
//   test/liveliness_test.dart:291 "livelinessGet returns empty after token
//   dropped" (assertion at :307)
//     -> "livelinessGet reports no reply once the token is closed"
//
//   test/liveliness_test.dart:310 "livelinessGet with custom timeout"
//   (assertions at :326-:327)
//     -> "a custom get timeout is honoured through the router"
//
//   test/liveliness_test.dart:784 "token appearance and disappearance arrive
//   as put then delete" (assertions at :797-:800) -- the FIFO pull carrier
//     -> "a fifo pull subscriber delivers put then delete through the router"
//
//   test/liveliness_test.dart:805 "the same transitions arrive through a ring
//   channel" (assertions at :818-:820) -- the RING pull carrier
//     -> "the same transitions arrive through a routed ring channel"
//
//   test/liveliness_test.dart:824 "history: true replays a token that was
//   already alive" (assertions at :837-:839) -- the pull carrier
//     -> "history: true replays a pre-existing token on the routed carrier"
//
//   test/liveliness_test.dart:843 "history omitted does NOT replay a
//   pre-existing token" (assertion at :856) -- the pull carrier
//     -> "history omitted does not replay on the routed carrier"
//
//   test/liveliness_test.dart:863 "recv() parks and wakes on this carrier"
//   (assertions at :880-:883)
//     -> "recv() parks and wakes on the routed carrier"
//
//   test/liveliness_test.dart:633 "a fifo channel delivers alive tokens, then
//   disconnects" (assertions at :645-:648) -- the pull GET carrier
//     -> "a fifo pullLivelinessGet delivers the alive token, then disconnects"
//
//   test/liveliness_test.dart:652 "the channel reaches the terminal state
//   with no tokens alive" (assertions at :661-:662) -- the pull GET carrier
//     -> "the routed pull get reaches the terminal state with nothing alive"
//
//   test/liveliness_test.dart:690 "Duration.zero is honoured here too"
//   (assertion at :703) -- the pull GET carrier
//     -> "Duration.zero is honoured through the router too"
//
// Three cells here carry no original: the split control, the withdrawn-before-
// attach edge, and the holder-session-death edge. They are named as such.
//
// WHY DELIVERY ITSELF IS THE OBSERVABLE
//
// Pointing two sessions at a router is not routing them: peers find each
// other by gossip and link DIRECTLY, so the router sits beside the path and
// the green is indistinguishable from the no-router case. Every leaf below is
// built by helpers/routed_topology.dart, which carries the three things that
// make the difference real -- the router's endpoint only, both discovery
// mechanisms off, and at least one leaf in client mode. With those in place
// no leaf-to-leaf link can form, so any event that arrives was carried by the
// router.
//
// THE READINESS LADDER USED HERE, AND WHY IT IS NOT A SLEEP
//
// A liveliness subscriber has no matching status to poll, so `awaitMatching`
// -- the exact gate the delivery counterparts use -- does not apply. Neither
// does `settleForDeclaration`: a fixed sleep would be a hope, and this file
// uses none. Two exact gates replace it, and both are LIVENESS legs as well
// as gates, so nothing here can pass early:
//
//   * _awaitRoutedObserver. A probe leaf on the same router declares and
//     withdraws throwaway tokens under a `/probe/` chunk until the cell's own
//     subscriber OBSERVES one. A first observed event through the router is
//     exactly the thing a later assertion depends on; nothing weaker proves
//     the subscription reached the token holder's side. Probe events are
//     routed into their own list (or skipped by the pull collector), so they
//     never enter a cell's assertion.
//
//   * _awaitTokenVisible. A probe leaf on the same router queries liveliness
//     until the token is (or is no longer) answered. That is the router's own
//     view of the token, taken from a third leaf rather than from the leaf
//     under test.
//
// Every wait has a ceiling and states it. The absence windows are fixed and
// stated; the positive paths beat them by a wide margin.
//
// PORTS: 19860-19869, this file's block of the unit's 19800-19899 band.
// 19860 carries the transition cells, 19861 is the unlinked router the split
// control declares into, 19862 the liveliness-get pair, 19863 the pull pair.

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/routed_topology.dart';

/// The router every transition cell crosses.
const _transitionRouterPort = 19860;

/// The second router, deliberately unlinked from [_transitionRouterPort].
const _splitRouterPort = 19861;

/// The liveliness-get pair's router.
const _getRouterPort = 19862;

/// The pull-carrier pair's router.
const _pullRouterPort = 19863;

/// The root every key expression in this file hangs off.
///
/// A plain, deterministic namespace is safe here where the originals need a
/// per-process nonce: these leaves have multicast and gossip off and dial
/// nothing but 127.0.0.1:1986x, so no session outside this file can reach
/// them and no wildcard assertion below can be perturbed from outside.
const _ns = 'zenoh/routed/liveliness';

/// The chunk that marks a readiness probe's key, never a cell's subject.
const _probeChunk = 'probe';

/// How long the split control waits before concluding nothing crossed.
///
/// It must exceed the positive path's convergence by a clear margin or a slow
/// green reads as a red. The positive cells here observe their first event in
/// well under a second once the gate returns; five seconds is the interval
/// this unit's other split controls already use.
const _splitWindow = Duration(seconds: 5);

/// How long a history-absence cell waits before concluding nothing replayed.
///
/// A replay, if it comes at all, comes with the subscription itself. The
/// originals allow two to three seconds for the same judgement.
const _absenceWindow = Duration(seconds: 3);

/// A liveliness stream split into the cell's samples and the gate's probes.
///
/// Splitting at the listener rather than filtering at the assertion is what
/// lets a cell read `isEmpty` and mean it: a readiness probe's put and delete
/// are not the cell's subject and must never be able to satisfy -- or
/// falsify -- one of its assertions.
typedef _Observed = ({List<Sample> samples, List<Sample> probes});

/// Collects [stream] into an [_Observed], registering its teardown.
_Observed _observe(Stream<Sample> stream, void Function()? close) {
  if (close != null) addTearDown(close);
  final samples = <Sample>[];
  final probes = <Sample>[];
  final subscription = stream.listen((sample) {
    if (sample.keyExpr.contains('/$_probeChunk/')) {
      probes.add(sample);
    } else {
      samples.add(sample);
    }
  });
  addTearDown(subscription.cancel);
  return (samples: samples, probes: probes);
}

/// Waits until a liveliness subscription is live THROUGH the router.
///
/// THE EXACT GATE, and the reason it exists is that the cheaper ones do not
/// answer the question. `awaitAttached` says the transport linked; it says
/// nothing about the subscriber's declaration having crossed the router --
/// and declaring a token before it has loses the event outright, because a
/// liveliness subscriber without history is told about transitions only, and
/// zenoh retains nothing for a subscriber that was not there yet.
///
/// A probe leaf declares a throwaway token under a `/probe/` chunk and
/// withdraws it; when the cell's own subscriber has SEEN one, the path the
/// cell depends on has demonstrably carried an event. Each attempt uses a
/// fresh key, so nothing here can be satisfied by stale state.
Future<void> _awaitRoutedObserver({
  required Session probeLeaf,
  required String namespace,
  required List<Sample> probes,
  Duration within = routedWaitTimeout,
}) async {
  final deadline = DateTime.now().add(within);
  var attempt = 0;
  while (DateTime.now().isBefore(deadline)) {
    final token = probeLeaf.declareLivelinessToken(
      '$namespace/$_probeChunk/${attempt++}',
    );
    final until = DateTime.now().add(const Duration(milliseconds: 250));
    while (probes.isEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    token.close();
    if (probes.isNotEmpty) return;
  }
  fail(
    'Timed out after ${within.inMilliseconds}ms waiting for a liveliness '
    'subscription on "$namespace" to observe a probe token through the '
    'router.',
  );
}

/// The pull-carrier form of [_awaitRoutedObserver].
///
/// RETURNS WHAT IT SWALLOWED, and that is the whole difference between this
/// and a gate that reads well. A channel-mode subscriber has no stream to
/// split, so this gate consumes from the very channel the cell then asserts
/// over -- and a first version discarded everything it took, which made the
/// no-history cell below pass identically WITH history requested. Measured:
/// the replay landed before the gate's probe and was drained away, so the
/// cell's zero was the drain's, not the carrier's. Anything that is not a
/// probe is therefore handed back, and a cell asserting an absence asserts
/// over this list as well as over what it collects afterwards.
Future<List<Sample>> _awaitRoutedPullObserver({
  required Session probeLeaf,
  required String namespace,
  required PullSubscriber pull,
  Duration within = routedWaitTimeout,
}) async {
  final carried = <Sample>[];
  final deadline = DateTime.now().add(within);
  var attempt = 0;
  while (DateTime.now().isBefore(deadline)) {
    final token = probeLeaf.declareLivelinessToken(
      '$namespace/$_probeChunk/${attempt++}',
    );
    var seen = false;
    final until = DateTime.now().add(const Duration(milliseconds: 250));
    while (!seen && DateTime.now().isBefore(until)) {
      final result = pull.tryRecv();
      if (result is RecvData<Sample>) {
        if (result.value.keyExpr.contains('/$_probeChunk/')) {
          seen = true;
        } else {
          carried.add(result.value);
        }
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    token.close();
    if (seen) {
      carried.addAll(await _drainQuiet(pull));
      return carried;
    }
  }
  fail(
    'Timed out after ${within.inMilliseconds}ms waiting for a pull '
    'liveliness subscriber on "$namespace" to observe a probe token through '
    'the router.',
  );
}

/// Empties [pull] of the gate's leftovers, returning anything that was not a
/// probe.
///
/// A probe's DELETE arrives after its PUT, so the gate would otherwise leave
/// one behind for the next `recv()` to return -- and on a ring of the
/// originals' capacity it would compete with the cell's own events for a
/// slot. What it must NOT do is silently eat a sample the cell would have
/// asserted over, so non-probe samples are handed back rather than dropped.
///
/// Bounded twice over: it stops once the channel has been quiet for [quiet],
/// and unconditionally at [within].
Future<List<Sample>> _drainQuiet(
  PullSubscriber pull, {
  Duration quiet = const Duration(milliseconds: 300),
  Duration within = const Duration(seconds: 3),
}) async {
  final carried = <Sample>[];
  final deadline = DateTime.now().add(within);
  var lastData = DateTime.now();
  while (DateTime.now().isBefore(deadline)) {
    final result = pull.tryRecv();
    if (result is RecvData<Sample>) {
      lastData = DateTime.now();
      if (!result.value.keyExpr.contains('/$_probeChunk/')) {
        carried.add(result.value);
      }
    } else if (result is RecvDisconnected<Sample>) {
      return carried;
    } else {
      if (DateTime.now().difference(lastData) > quiet) return carried;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  return carried;
}

/// Waits until a probe leaf's liveliness query agrees with [expectAlive].
///
/// The router's own view of a token, taken from a THIRD leaf rather than from
/// the leaf under test -- so a cell that then asserts presence or absence is
/// not asserting it against its own instrument. Each attempt carries its own
/// short query timeout, which paces the loop; the loop stops at [within].
Future<void> _awaitTokenVisible(
  Session probeLeaf,
  String keyExpr, {
  bool expectAlive = true,
  Duration within = routedWaitTimeout,
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    final replies = await probeLeaf
        .livelinessGet(keyExpr, timeout: const Duration(milliseconds: 500))
        .toList();
    if (replies.any((reply) => reply.isOk) == expectAlive) return;
  }
  fail(
    'Timed out after ${within.inMilliseconds}ms waiting for "$keyExpr" to be '
    '${expectAlive ? 'alive' : 'gone'} in a probe leaf view through the '
    'router.',
  );
}

/// Polls [pull] for [want] non-probe samples, or until [timeout].
Future<List<Sample>> _collectPull(
  PullSubscriber pull,
  int want, {
  Duration timeout = routedWaitTimeout,
}) async {
  final got = <Sample>[];
  final deadline = DateTime.now().add(timeout);
  while (got.length < want && DateTime.now().isBefore(deadline)) {
    final result = pull.tryRecv();
    if (result is RecvData<Sample>) {
      if (!result.value.keyExpr.contains('/$_probeChunk/')) {
        got.add(result.value);
      }
    } else if (result is RecvDisconnected<Sample>) {
      break;
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  return got;
}

/// Drains a [PullReplies] to its terminal state, or until [timeout].
Future<List<Reply>> _drainReplies(
  PullReplies replies, {
  Duration timeout = routedWaitTimeout,
}) async {
  final got = <Reply>[];
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final result = replies.tryRecv();
    if (result is RecvData<Reply>) {
      got.add(result.value);
    } else if (result is RecvDisconnected<Reply>) {
      return got;
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  return got;
}

void main() {
  group('A liveliness transition crosses one hosted router '
      '(TCP 19860, split 19861)', () {
    late HostedRouter router;
    late HostedRouter splitRouter;
    late Session tokenLeaf;
    late Session observerLeaf;
    late Session probeLeaf;
    late Session splitTokenLeaf;
    late Session splitProbeLeaf;

    setUpAll(() async {
      router = await HostedRouter.open(_transitionRouterPort);
      splitRouter = await HostedRouter.open(_splitRouterPort);

      tokenLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      observerLeaf = await Session.open(
        config: router.leafConfig(LeafMode.peer),
      );
      probeLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      // Identical flags and identical role to tokenLeaf. The ONLY difference
      // is which router it dials, which is what makes the split control's
      // zero attributable to the path rather than to the leaf.
      splitTokenLeaf = await Session.open(
        config: splitRouter.leafConfig(LeafMode.client),
      );
      splitProbeLeaf = await Session.open(
        config: splitRouter.leafConfig(LeafMode.client),
      );

      await router.awaitAttached(tokenLeaf);
      await router.awaitAttached(observerLeaf);
      await router.awaitAttached(probeLeaf);
      await splitRouter.awaitAttached(splitTokenLeaf);
      await splitRouter.awaitAttached(splitProbeLeaf);
    });

    tearDownAll(() {
      splitProbeLeaf.close();
      splitTokenLeaf.close();
      probeLeaf.close();
      observerLeaf.close();
      tokenLeaf.close();
      splitRouter.close();
      router.close();
    });

    test('each leaf reports exactly the router it was pointed at', () {
      // The precondition every other cell in this group rests on, asserted
      // once and from the LEAF's own view. Without it a universal zero would
      // be satisfied by leaves that connected to nothing at all.
      for (final leaf in [tokenLeaf, observerLeaf, probeLeaf]) {
        expect(leaf.routersZid(), hasLength(1));
        expect(leaf.routersZid().single, equals(router.zid));
      }
      for (final leaf in [splitTokenLeaf, splitProbeLeaf]) {
        expect(leaf.routersZid(), hasLength(1));
        expect(leaf.routersZid().single, equals(splitRouter.zid));
      }
      expect(splitRouter.zid, isNot(equals(router.zid)));
    });

    test('a token declaration crosses the router as a put', () async {
      // Counterpart of liveliness_test.dart:124.
      const ns = '$_ns/declare';
      final sub = observerLeaf.declareLivelinessSubscriber('$ns/**');
      final observed = _observe(sub.stream, sub.close);
      await _awaitRoutedObserver(
        probeLeaf: probeLeaf,
        namespace: ns,
        probes: observed.probes,
      );

      final token = tokenLeaf.declareLivelinessToken('$ns/1');
      addTearDown(token.close);

      await awaitCondition(
        () => observed.samples.isNotEmpty,
        description: 'the routed observer to see the token declaration',
      );
      expect(observed.samples.first.kind, equals(SampleKind.put));
      expect(observed.samples.first.keyExpr, contains('$ns/1'));
    });

    test('closing the token crosses the router as a delete', () async {
      // Counterpart of liveliness_test.dart:139, which closes the token
      // rather than killing its holder -- this one closes it the same way.
      // The holder-disappearance shape is a separate cell below.
      const ns = '$_ns/close';
      final sub = observerLeaf.declareLivelinessSubscriber('$ns/**');
      final observed = _observe(sub.stream, sub.close);
      await _awaitRoutedObserver(
        probeLeaf: probeLeaf,
        namespace: ns,
        probes: observed.probes,
      );

      final token = tokenLeaf.declareLivelinessToken('$ns/1');
      await awaitCondition(
        () => observed.samples.isNotEmpty,
        description: 'the routed observer to see the token declaration',
      );

      token.close();
      await awaitCondition(
        () => observed.samples.length >= 2,
        description: 'the routed observer to see the token withdrawal',
      );

      expect(observed.samples[0].kind, equals(SampleKind.put));
      expect(observed.samples[1].kind, equals(SampleKind.delete));
      expect(observed.samples[1].keyExpr, contains('$ns/1'));
    });

    test('two tokens produce two puts and two individual deletes', () async {
      // Counterpart of liveliness_test.dart:164. The original sleeps between
      // the closes; this one gates on the count each time, so the ordering it
      // asserts is observed rather than assumed.
      const ns = '$_ns/multiple';
      final sub = observerLeaf.declareLivelinessSubscriber('$ns/**');
      final observed = _observe(sub.stream, sub.close);
      await _awaitRoutedObserver(
        probeLeaf: probeLeaf,
        namespace: ns,
        probes: observed.probes,
      );

      final first = tokenLeaf.declareLivelinessToken('$ns/1');
      final second = tokenLeaf.declareLivelinessToken('$ns/2');
      await awaitCondition(
        () => observed.samples.length >= 2,
        description: 'the routed observer to see both declarations',
      );

      first.close();
      await awaitCondition(
        () => observed.samples.length >= 3,
        description: 'the routed observer to see the first withdrawal',
      );
      second.close();
      await awaitCondition(
        () => observed.samples.length >= 4,
        description: 'the routed observer to see the second withdrawal',
      );

      final puts = observed.samples
          .where((s) => s.kind == SampleKind.put)
          .toList();
      final deletes = observed.samples
          .where((s) => s.kind == SampleKind.delete)
          .toList();
      expect(puts, hasLength(2));
      expect(deletes, hasLength(2));
      expect(
        puts.map((s) => s.keyExpr).toSet(),
        equals({'$ns/1', '$ns/2'}),
      );
      expect(
        deletes.map((s) => s.keyExpr).toSet(),
        equals({'$ns/1', '$ns/2'}),
      );
    });

    test('neither the declaration nor the withdrawal crosses two unlinked '
        'routers', () async {
      // THE SPLIT CONTROL, and it carries no original: the default suite has
      // no cell that could distinguish a routed liveliness event from a
      // directly-linked one. Same key, same roles, same flags as the two
      // cells above; the token is declared on the other router.
      const ns = '$_ns/split';
      final sub = observerLeaf.declareLivelinessSubscriber('$ns/**');
      final observed = _observe(sub.stream, sub.close);

      // THE OBSERVING SIDE'S READINESS FIRST, so a zero can never be a
      // subscriber that failed to start: this returns only once this very
      // subscriber has observed a probe token cross THIS router.
      await _awaitRoutedObserver(
        probeLeaf: probeLeaf,
        namespace: ns,
        probes: observed.probes,
      );

      final token = splitTokenLeaf.declareLivelinessToken('$ns/1');
      // And the TOKEN's readiness, from a leaf of the router it was declared
      // on -- so the zero below is not a token that was never alive.
      await _awaitTokenVisible(splitProbeLeaf, '$ns/**');

      await Future<void>.delayed(_splitWindow);
      expect(observed.samples, isEmpty);

      // A second, independent reading of the same absence, through the query
      // surface rather than the subscription one: the live token is not
      // visible from the other router at all.
      final crossReplies = await probeLeaf
          .livelinessGet('$ns/**', timeout: const Duration(seconds: 1))
          .toList();
      expect(crossReplies, isEmpty);

      token.close();
      await Future<void>.delayed(_splitWindow);
      expect(observed.samples, isEmpty);
    });

    test('history replays a token already alive through the router', () async {
      // Counterpart of liveliness_test.dart:456. No probe gate is needed or
      // wanted here: with history the token is replayed to the subscription
      // itself, so the exact readiness is the token being visible through the
      // router BEFORE the observer attaches.
      const ns = '$_ns/history';
      final token = tokenLeaf.declareLivelinessToken('$ns/pre');
      addTearDown(token.close);
      await _awaitTokenVisible(probeLeaf, '$ns/**');

      final sub = observerLeaf.declareLivelinessSubscriber(
        '$ns/**',
        history: true,
      );
      final observed = _observe(sub.stream, sub.close);

      await awaitCondition(
        () => observed.samples.isNotEmpty,
        description: 'the routed observer to be replayed the live token',
      );
      expect(observed.samples.first.kind, equals(SampleKind.put));
      expect(observed.samples.first.keyExpr, contains('$ns/pre'));
    });

    test('history omitted does not replay a pre-existing token', () async {
      // Counterpart of liveliness_test.dart:478, which is the control that
      // makes the cell above an observation rather than a coincidence.
      const ns = '$_ns/nohistory';
      final token = tokenLeaf.declareLivelinessToken('$ns/pre');
      addTearDown(token.close);
      await _awaitTokenVisible(probeLeaf, '$ns/**');

      final sub = observerLeaf.declareLivelinessSubscriber('$ns/**');
      final observed = _observe(sub.stream, sub.close);
      await _awaitRoutedObserver(
        probeLeaf: probeLeaf,
        namespace: ns,
        probes: observed.probes,
      );

      await Future<void>.delayed(_absenceWindow);
      expect(observed.samples, isEmpty);

      // THE LIVENESS LEG, in this cell rather than beside it: the same
      // subscriber is told about a token declared NOW. Without it the zero
      // above would be satisfied by a subscription that never worked.
      final later = tokenLeaf.declareLivelinessToken('$ns/after');
      addTearDown(later.close);
      await awaitCondition(
        () => observed.samples.isNotEmpty,
        description: 'the routed observer to see a later declaration',
      );
      expect(observed.samples.first.keyExpr, contains('$ns/after'));
    });

    test('a token withdrawn before the observer attaches is not reported, '
        'even with history', () async {
      // No original: the edge that separates history RECOVERY from a stale
      // state left behind in the router. The token is declared, confirmed
      // alive through the router, withdrawn, and confirmed gone -- all before
      // the observer exists.
      const ns = '$_ns/withdrawn';
      final token = tokenLeaf.declareLivelinessToken('$ns/gone');
      await _awaitTokenVisible(probeLeaf, '$ns/**');
      token.close();
      await _awaitTokenVisible(probeLeaf, '$ns/**', expectAlive: false);

      final sub = observerLeaf.declareLivelinessSubscriber(
        '$ns/**',
        history: true,
      );
      final observed = _observe(sub.stream, sub.close);
      await _awaitRoutedObserver(
        probeLeaf: probeLeaf,
        namespace: ns,
        probes: observed.probes,
      );

      await Future<void>.delayed(_absenceWindow);
      expect(observed.samples, isEmpty);

      // The liveness leg: this subscriber does report a token that is alive.
      final later = tokenLeaf.declareLivelinessToken('$ns/after');
      addTearDown(later.close);
      await awaitCondition(
        () => observed.samples.isNotEmpty,
        description: 'the routed observer to see a later declaration',
      );
      expect(observed.samples.first.keyExpr, contains('$ns/after'));
    });

    test(
      'a holder session going away crosses the router as a delete',
      () async {
        // No original closes the HOLDER: every liveliness cell in the default
        // suite withdraws the token by hand. This is the shape a deployment
        // actually depends on -- a peer disappearing without undeclaring
        // anything -- and the router is what has to notice.
        //
        // The holder is its own leaf so its death costs the group nothing. The
        // wait for the delete is the helper's 10 s ceiling: a router notices a
        // closed session on the transport itself, not by lease expiry, so this
        // is far above the observed convergence and is a ceiling rather than a
        // delay.
        const ns = '$_ns/holder';
        final sub = observerLeaf.declareLivelinessSubscriber('$ns/**');
        final observed = _observe(sub.stream, sub.close);
        await _awaitRoutedObserver(
          probeLeaf: probeLeaf,
          namespace: ns,
          probes: observed.probes,
        );

        final holder = await Session.open(
          config: router.leafConfig(LeafMode.client),
        );
        await router.awaitAttached(holder);
        final token = holder.declareLivelinessToken('$ns/1');
        // Closed only in teardown, AFTER its session is gone: the point of the
        // cell is that nothing undeclares it.
        addTearDown(token.close);

        await awaitCondition(
          () => observed.samples.isNotEmpty,
          description: 'the routed observer to see the declaration',
        );
        expect(observed.samples.first.kind, equals(SampleKind.put));

        holder.close();
        await awaitCondition(
          () => observed.samples.length >= 2,
          description: 'the routed observer to see the holder disappear',
        );
        expect(observed.samples[1].kind, equals(SampleKind.delete));
        expect(observed.samples[1].keyExpr, contains('$ns/1'));
      },
    );

    test(
      'the background carrier delivers put then delete through the router',
      () async {
        // Counterpart of liveliness_test.dart:371 -- the same claim through the
        // handle-less carrier, which is a different declaration entry and so
        // gets its own counterpart rather than being collapsed into the one
        // above.
        const ns = '$_ns/background';
        final stream = observerLeaf.declareBackgroundLivelinessSubscriber(
          '$ns/**',
        );
        final observed = _observe(stream, null);
        await _awaitRoutedObserver(
          probeLeaf: probeLeaf,
          namespace: ns,
          probes: observed.probes,
        );

        final token = tokenLeaf.declareLivelinessToken('$ns/1');
        await awaitCondition(
          () => observed.samples.isNotEmpty,
          description: 'the background carrier to see the declaration',
        );
        token.close();
        await awaitCondition(
          () => observed.samples.length >= 2,
          description: 'the background carrier to see the withdrawal',
        );

        expect(observed.samples[0].kind, equals(SampleKind.put));
        expect(observed.samples[1].kind, equals(SampleKind.delete));
        expect(observed.samples[1].keyExpr, contains('$ns/1'));
      },
    );

    test('the background carrier replays a pre-existing token', () async {
      // Counterpart of liveliness_test.dart:392.
      const ns = '$_ns/backgroundhistory';
      final token = tokenLeaf.declareLivelinessToken('$ns/pre');
      addTearDown(token.close);
      await _awaitTokenVisible(probeLeaf, '$ns/**');

      final stream = observerLeaf.declareBackgroundLivelinessSubscriber(
        '$ns/**',
        history: true,
      );
      final observed = _observe(stream, null);

      await awaitCondition(
        () => observed.samples.isNotEmpty,
        description: 'the background carrier to be replayed the live token',
      );
      expect(observed.samples.first.kind, equals(SampleKind.put));
      expect(observed.samples.first.keyExpr, contains('$ns/pre'));
    });
  });

  group('livelinessGet crosses one hosted router (TCP 19862)', () {
    late HostedRouter router;
    late Session getterLeaf;
    late Session tokenLeaf;
    late Session probeLeaf;

    setUpAll(() async {
      router = await HostedRouter.open(_getRouterPort);
      // The slice's roles for this family: a client getter, a peer holder.
      getterLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      tokenLeaf = await Session.open(
        config: router.leafConfig(LeafMode.peer),
      );
      probeLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      await router.awaitAttached(getterLeaf);
      await router.awaitAttached(tokenLeaf);
      await router.awaitAttached(probeLeaf);
    });

    tearDownAll(() {
      probeLeaf.close();
      tokenLeaf.close();
      getterLeaf.close();
      router.close();
    });

    test('each leaf reports exactly the router it was pointed at', () {
      for (final leaf in [getterLeaf, tokenLeaf, probeLeaf]) {
        expect(leaf.routersZid(), hasLength(1));
        expect(leaf.routersZid().single, equals(router.zid));
      }
    });

    test('livelinessGet reaches the live token through the router', () async {
      // Counterpart of liveliness_test.dart:261.
      const ns = '$_ns/get/alive';
      final token = tokenLeaf.declareLivelinessToken('$ns/1');
      addTearDown(token.close);
      await _awaitTokenVisible(probeLeaf, '$ns/**');

      final replies = await getterLeaf
          .livelinessGet('$ns/**', timeout: const Duration(seconds: 2))
          .toList();

      expect(replies, hasLength(1));
      expect(replies.single.isOk, isTrue);
      expect(replies.single.ok.keyExpr, contains('$ns/1'));
    });

    test('livelinessGet reports no reply where nothing is alive', () async {
      // Counterpart of liveliness_test.dart:279. The original asserts the
      // zero alone; this one follows it with a token in the SAME namespace
      // that the SAME getter then finds, so the zero cannot be a getter that
      // never worked.
      const ns = '$_ns/get/nobody';
      final before = await getterLeaf
          .livelinessGet('$ns/**', timeout: const Duration(seconds: 2))
          .toList();
      expect(before, isEmpty);

      final token = tokenLeaf.declareLivelinessToken('$ns/1');
      addTearDown(token.close);
      await _awaitTokenVisible(probeLeaf, '$ns/**');

      final after = await getterLeaf
          .livelinessGet('$ns/**', timeout: const Duration(seconds: 2))
          .toList();
      expect(after, hasLength(1));
      expect(after.single.ok.keyExpr, contains('$ns/1'));
    });

    test('livelinessGet reports no reply once the token is closed', () async {
      // Counterpart of liveliness_test.dart:291, and the shape the slice asks
      // for: one query with the token live, one without.
      const ns = '$_ns/get/dropped';
      final token = tokenLeaf.declareLivelinessToken('$ns/1');
      await _awaitTokenVisible(probeLeaf, '$ns/**');

      final alive = await getterLeaf
          .livelinessGet('$ns/**', timeout: const Duration(seconds: 2))
          .toList();
      expect(alive, hasLength(1));
      expect(alive.single.ok.keyExpr, contains('$ns/1'));

      token.close();
      await _awaitTokenVisible(probeLeaf, '$ns/**', expectAlive: false);

      final gone = await getterLeaf
          .livelinessGet('$ns/**', timeout: const Duration(seconds: 2))
          .toList();
      expect(gone, isEmpty);
    });

    test('a custom get timeout is honoured through the router', () async {
      // Counterpart of liveliness_test.dart:310 -- the same claim with the
      // timeout stated explicitly rather than defaulted.
      const ns = '$_ns/get/timeout';
      final token = tokenLeaf.declareLivelinessToken('$ns/1');
      addTearDown(token.close);
      await _awaitTokenVisible(probeLeaf, '$ns/**');

      final replies = await getterLeaf
          .livelinessGet('$ns/**', timeout: const Duration(seconds: 5))
          .toList();

      expect(replies, hasLength(1));
      expect(replies.single.isOk, isTrue);
    });
  });

  group('The pull liveliness carriers cross one hosted router (TCP 19863)', () {
    late HostedRouter router;
    late Session pullLeaf;
    late Session tokenLeaf;
    late Session probeLeaf;

    setUpAll(() async {
      router = await HostedRouter.open(_pullRouterPort);
      // The slice's roles for this family: a peer consumer, a client holder.
      pullLeaf = await Session.open(
        config: router.leafConfig(LeafMode.peer),
      );
      tokenLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      probeLeaf = await Session.open(
        config: router.leafConfig(LeafMode.client),
      );
      await router.awaitAttached(pullLeaf);
      await router.awaitAttached(tokenLeaf);
      await router.awaitAttached(probeLeaf);
    });

    tearDownAll(() {
      probeLeaf.close();
      tokenLeaf.close();
      pullLeaf.close();
      router.close();
    });

    test('each leaf reports exactly the router it was pointed at', () {
      for (final leaf in [pullLeaf, tokenLeaf, probeLeaf]) {
        expect(leaf.routersZid(), hasLength(1));
        expect(leaf.routersZid().single, equals(router.zid));
      }
    });

    test(
      'a fifo pull subscriber delivers put then delete through the router',
      () async {
        // Counterpart of liveliness_test.dart:784.
        const ns = '$_ns/pull/fifo';
        final pull = pullLeaf.declarePullLivelinessSubscriber(
          '$ns/**',
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(pull.close);
        await _awaitRoutedPullObserver(
          probeLeaf: probeLeaf,
          namespace: ns,
          pull: pull,
        );

        final token = tokenLeaf.declareLivelinessToken('$ns/1');
        final put = await _collectPull(pull, 1);
        expect(put, hasLength(1));
        token.close();

        final got = await _collectPull(pull, 1);
        expect(put.single.kind, equals(SampleKind.put));
        expect(put.single.keyExpr, contains('$ns/1'));
        expect(got, hasLength(1));
        expect(got.single.kind, equals(SampleKind.delete));
        expect(got.single.keyExpr, contains('$ns/1'));
      },
    );

    test('the same transitions arrive through a routed ring channel', () async {
      // Counterpart of liveliness_test.dart:805 -- the same claim on the ring
      // carrier, which is a different handler and so gets its own cell.
      const ns = '$_ns/pull/ring';
      final pull = pullLeaf.declarePullLivelinessSubscriber(
        '$ns/**',
        kind: ChannelKind.ring,
        capacity: 4,
      );
      addTearDown(pull.close);
      await _awaitRoutedPullObserver(
        probeLeaf: probeLeaf,
        namespace: ns,
        pull: pull,
      );

      final token = tokenLeaf.declareLivelinessToken('$ns/1');
      final put = await _collectPull(pull, 1);
      token.close();
      final deleted = await _collectPull(pull, 1);

      expect(
        [...put, ...deleted].map((s) => s.kind).toList(),
        equals([SampleKind.put, SampleKind.delete]),
      );
    });

    test(
      'history: true replays a pre-existing token on the routed carrier',
      () async {
        // Counterpart of liveliness_test.dart:824.
        const ns = '$_ns/pull/history';
        final token = tokenLeaf.declareLivelinessToken('$ns/pre');
        addTearDown(token.close);
        await _awaitTokenVisible(probeLeaf, '$ns/**');

        final pull = pullLeaf.declarePullLivelinessSubscriber(
          '$ns/**',
          kind: ChannelKind.fifo,
          capacity: 4,
          history: true,
        );
        addTearDown(pull.close);

        final got = await _collectPull(pull, 1);
        expect(got, hasLength(1));
        expect(got.single.kind, equals(SampleKind.put));
        expect(got.single.keyExpr, contains('$ns/pre'));
      },
    );

    test('history omitted does not replay on the routed carrier', () async {
      // Counterpart of liveliness_test.dart:843, the control for the cell
      // above. The liveness leg is in this cell: after the zero, a token
      // declared NOW must reach the same handle.
      const ns = '$_ns/pull/nohistory';
      final token = tokenLeaf.declareLivelinessToken('$ns/pre');
      addTearDown(token.close);
      await _awaitTokenVisible(probeLeaf, '$ns/**');

      final pull = pullLeaf.declarePullLivelinessSubscriber(
        '$ns/**',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);
      // THE GATE'S CARRYOVER IS PART OF THE OBSERVATION, not noise. A replay
      // would arrive with the declaration, which is BEFORE the gate's probe,
      // so a cell that only looked at what it collected afterwards would be
      // blind to it -- measured, on the first version of this file.
      final carried = await _awaitRoutedPullObserver(
        probeLeaf: probeLeaf,
        namespace: ns,
        pull: pull,
      );
      expect(carried, isEmpty);

      expect(await _collectPull(pull, 1, timeout: _absenceWindow), isEmpty);

      final later = tokenLeaf.declareLivelinessToken('$ns/after');
      addTearDown(later.close);
      final got = await _collectPull(pull, 1);
      expect(got, hasLength(1));
      expect(got.single.keyExpr, contains('$ns/after'));
    });

    test('recv() parks and wakes on the routed carrier', () async {
      // Counterpart of liveliness_test.dart:863 -- the park-then-wake path,
      // with the wake carried by the router.
      const ns = '$_ns/pull/wake';
      final pull = pullLeaf.declarePullLivelinessSubscriber(
        '$ns/**',
        kind: ChannelKind.fifo,
        capacity: 4,
      );
      addTearDown(pull.close);
      await _awaitRoutedPullObserver(
        probeLeaf: probeLeaf,
        namespace: ns,
        pull: pull,
      );

      final pending = pull.recv();
      final token = tokenLeaf.declareLivelinessToken('$ns/late');
      addTearDown(token.close);

      final result = await pending.timeout(routedWaitTimeout);
      expect(result, isA<RecvData<Sample>>());
      final sample = (result as RecvData<Sample>).value;
      expect(sample.kind, equals(SampleKind.put));
      expect(sample.keyExpr, contains('$ns/late'));
    });

    test(
      'a fifo pullLivelinessGet delivers the alive token, then disconnects',
      () async {
        // Counterpart of liveliness_test.dart:633 -- the query carrier.
        const ns = '$_ns/pullget/fifo';
        final token = tokenLeaf.declareLivelinessToken('$ns/1');
        addTearDown(token.close);
        await _awaitTokenVisible(probeLeaf, '$ns/**');

        final replies = pullLeaf.pullLivelinessGet(
          '$ns/**',
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(replies.dispose);

        final got = await _drainReplies(replies);
        expect(got, hasLength(1));
        expect(got.single.isOk, isTrue);
        expect(got.single.ok.keyExpr, contains('$ns/1'));
        expect(replies.tryRecv(), isA<RecvDisconnected<Reply>>());
      },
    );

    test(
      'the routed pull get reaches the terminal state with nothing alive',
      () async {
        // Counterpart of liveliness_test.dart:652. The liveness leg follows in
        // the same cell: the same carrier on a namespace where a token IS alive
        // returns one, so the zero is about the namespace and not the carrier.
        const ns = '$_ns/pullget/nobody';
        final empty = pullLeaf.pullLivelinessGet(
          '$ns/**',
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(empty.dispose);

        expect(await _drainReplies(empty), isEmpty);
        expect(empty.tryRecv(), isA<RecvDisconnected<Reply>>());

        final token = tokenLeaf.declareLivelinessToken('$ns/1');
        addTearDown(token.close);
        await _awaitTokenVisible(probeLeaf, '$ns/**');

        final live = pullLeaf.pullLivelinessGet(
          '$ns/**',
          kind: ChannelKind.fifo,
          capacity: 4,
        );
        addTearDown(live.dispose);
        expect(await _drainReplies(live), hasLength(1));
      },
    );

    test('Duration.zero is honoured through the router too', () async {
      // Counterpart of liveliness_test.dart:690. Canon applies a zero
      // liveliness timeout unconditionally rather than substituting a default
      // -- the routed path inherits that contract rather than a stricter one.
      const ns = '$_ns/pullget/zero';
      final token = tokenLeaf.declareLivelinessToken('$ns/1');
      addTearDown(token.close);
      await _awaitTokenVisible(probeLeaf, '$ns/**');

      final replies = pullLeaf.pullLivelinessGet(
        '$ns/**',
        kind: ChannelKind.fifo,
        capacity: 4,
        timeout: Duration.zero,
      );
      addTearDown(replies.dispose);

      expect(await _drainReplies(replies), hasLength(1));
    });
  });
}
