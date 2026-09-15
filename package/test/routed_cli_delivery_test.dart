@Timeout(Duration(minutes: 3))
library;

// Delivery through a router, driven by the CLI examples themselves.
//
// Eight cells in the default suite certify that our example binaries exchange
// data -- and every one of them certifies it over a DIRECT link, either
// between a spawned example and an in-process session or between two spawned
// examples that listen and dial each other. This file adds their routed
// counterparts. Nothing here replaces anything: all eight originals stay
// exactly where they are, unedited, and keep certifying the direct path.
//
// THE ORIGINALS, AND THE COUNTERPART CARRYING EACH CLAIM
//
//   test/z_sub_cli_test.dart:37 "receives a sample from in-process put"
//   (asserts stdout contains 'Received PUT' and the payload, :83-:85)
//     -> "a spawned put crosses the router to a spawned subscriber"
//
//   test/z_queryable_cli_test.dart:58 "responds to in-process get"
//   (asserts the reply arrived and the queryable printed both canon lines,
//   :110-:126)
//     -> "a spawned queryable answers a spawned getter through the router"
//
//   test/z_queryable_with_channels_cli_test.dart:15 "answers a query from its
//   recv loop, in canon shape" (asserts the exact reply line and the
//   example's own Received Query line, :43-:54)
//     -> "the channel queryable answers a routed getter from its recv loop"
//
//   test/z_non_blocking_get_cli_test.dart:47 "prints a received reply in
//   canon shape" (asserts exit 0 and the exact canon reply line, :75-:79)
//     -> "a non-blocking get through the router reports its completion
//        honestly"
//
//   test/z_storage_cli_test.dart:131 "put then query returns stored value"
//   (asserts the getter's stdout contains the stored value, :188-:195)
//     -> "a spawned storage stores a routed put and serves a routed query"
//
//   test/z_storage_cli_test.dart:203 "delete removes from storage then query
//   omits deleted key" (asserts val2 present and val1 absent, :285-:296)
//     -> "a routed delete removes the entry and the routed query omits it"
//
//   test/z_pull_cli_test.dart:77 "receives sample from in-process put"
//   (asserts stdout contains 'Received PUT' and the payload, :138-:140; the
//   ring's one-sample-per-keypress granularity is a DIFFERENT original, at
//   :155, and stays where it is)
//     -> "a pull subscriber's buffered sample survives the router hop"
//
//   test/z_advanced_sub_cli_test.dart:44 "pub-to-sub e2e with history"
//   (asserts 'Received PUT' and the pre-existing sample index [   0],
//   :101-:103)
//     -> "a spawned advanced subscriber recovers history through the router"
//
// WHY DELIVERY ITSELF IS THE OBSERVABLE HERE
//
// Pointing two processes at a router is not routing them. Peers find each
// other by gossip and link DIRECTLY, so the router sits beside the path and
// the green is indistinguishable from the no-router case. Every leaf below is
// spawned with helpers/routed_topology.dart's own flag block, which carries
// the three things that make the difference real: the router's endpoint only
// and never a listen endpoint, multicast scouting and gossip both off, and at
// least one leaf of each pair in client mode. With those in place no
// leaf-to-leaf link can form, so anything that arrives was carried by the
// router.
//
// THE NEGATIVE CONTROL, AND WHY ITS ZERO IS WORTH READING
//
// "the same query across two unlinked routers returns no reply" runs the
// identical pair of examples with the identical flags, the getter dialling a
// SECOND router that nothing links to the first. Its zero means something
// only because the queryable's readiness is established FIRST, and
// established by a LIVENESS leg rather than by a banner: a probe getter on
// the shared router receives the reply before the split getter is ever
// spawned. So the zero cannot be a process that failed to start, and it
// cannot be a queryable that never answered anybody.
//
// EVERY WAIT IS A BOUNDED WAIT-FOR-CONDITION
//
// The original CLI groups ride fixed sleeps -- "Give the TCP connection time
// to negotiate", "Extra time for TCP listener to bind", "Wait for
// propagation". A router hop lengthens convergence, so inheriting those would
// be inheriting a race and making it worse. Nothing here sleeps: readiness is
// the process's own marker, then the router's own view, then an exact gate
// (a probe publisher seeing the subscriber, or a probe getter receiving the
// reply). The last group asserts that property over this file's source, so it
// keeps holding for cells added later.
//
// PORTS: 19830-19839, this file's block of the unit's 19800-19899 band.
// 19830 the pub/sub pair; 19831 the unlinked router the split control dials;
// 19832 the query family; 19833 the storage family; 19834 the pull
// subscriber; 19835 the non-blocking getter; 19836 the advanced pair.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/cli_process.dart';
import 'helpers/routed_topology.dart';

/// The Dart executable running this suite.
///
/// Spawning `fvm` would hardcode a tool that need not be on PATH and would
/// resolve a *different* Dart -- and SIGTERM to `fvm` does not reach the
/// grandchild it starts.
final String _dartExe = Platform.resolvedExecutable;

/// The pub/sub pair's router.
const _pubSubRouterPort = 19830;

/// The second router, deliberately unlinked from every other one here.
const _splitRouterPort = 19831;

/// The query family's router.
const _queryRouterPort = 19832;

/// The storage family's router.
const _storageRouterPort = 19833;

/// The pull subscriber's router.
const _pullRouterPort = 19834;

/// The non-blocking getter's router.
const _nonBlockingRouterPort = 19835;

/// The advanced pair's router.
const _advancedRouterPort = 19836;

/// The ceiling on every readiness gate and every delivery wait in this file.
///
/// SIZED, not guessed, and it is a ceiling rather than a delay: every wait
/// below returns as soon as its condition holds. A spawned `dart run` reaches
/// its banner in ~1.3 s idle and ~5.4 s under heavy CPU contention
/// (helpers/cli_process.dart states the measurement), and a router hop adds a
/// second leg of convergence on top of that. 30 s is a bound for a process
/// spawn plus a routed declaration, not a repair for a red.
const _readyWait = Duration(seconds: 30);

/// The ceiling on a one-shot example that runs to completion.
///
/// The longest one here is a non-blocking get given a 20 s query timeout, so
/// this has to clear that plus the spawn.
const _runWait = Duration(seconds: 60);

/// The marker `z_pull` prints instead of the CTRL-C banner.
///
/// It is the one example that does not print [cliReady]: it prompts for input
/// and reads stdin instead (example/z_pull.dart:47).
const _pullReady = 'Press <enter> to pull data...';

/// This file's own path, read by the wait-shape cell at the bottom.
const _selfPath = 'test/routed_cli_delivery_test.dart';

/// A lone `(`, used to assemble that cell's scan needles by interpolation.
///
/// The scan reads THIS file, so a needle spelled out verbatim would match its
/// own definition and report the guard as the violation. Interpolating the
/// parenthesis keeps the needle out of the source it searches.
const _paren = '(';

/// The one wait shape that is legitimate elsewhere and unnecessary here, in
/// the same split-so-it-cannot-self-match form as [_paren].
const _settleNeedle =
    'settleFor'
    'Declaration';

/// A spawned example leaf and the stdout it has produced so far.
class _Leaf {
  _Leaf(this.process, this.out, this.err);

  /// The spawned process.
  final Process process;

  /// Everything it has written to stdout.
  final StringBuffer out;

  /// Everything it has written to stderr.
  ///
  /// Drained rather than left to fill its pipe, and read only in failure
  /// reasons. It is never asserted to be silent: canon prints a transport
  /// event error on every routed teardown, so a silence assertion here would
  /// be about the environment rather than about the subject.
  final StringBuffer err;
}

/// The line `z_sub`, `z_pull` and `z_storage` print for a delivered sample.
String _receivedLine(String kind, String key, String payload) =>
    ">> [Subscriber] Received $kind ('$key': '$payload')";

/// The line `z_get` and `z_non_blocking_get` print for an OK reply.
String _replyLine(String key, String payload) =>
    ">> Received ('$key': '$payload')";

/// Spawns [example] as a long-running leaf of [router] in [mode].
///
/// The flag block comes from the helper rather than being spelled here, so a
/// spawned counterpart and its in-process sibling cannot express different
/// topologies while reading alike.
Future<_Leaf> _spawnLeaf(
  HostedRouter router,
  LeafMode mode,
  String example,
  List<String> args,
) async {
  final process = await Process.start(_dartExe, [
    'run',
    'example/$example',
    ...args,
    ...router.leafArgs(mode),
  ], workingDirectory: Directory.current.path);
  addTearDown(() => forceKill(process));

  // A killed process's stdin completes with a broken pipe. Nothing reads that
  // failure, and an unobserved one surfaces as an unhandled async error that
  // fails an unrelated cell, so it is discarded at the source.
  process.stdin.done.ignore();

  final out = StringBuffer();
  final err = StringBuffer();
  process.stdout.transform(const SystemEncoding().decoder).listen(out.write);
  process.stderr.transform(const SystemEncoding().decoder).listen(err.write);
  return _Leaf(process, out, err);
}

/// Runs [example] to completion as a one-shot leaf of [router] in [mode].
Future<ProcessResult> _runLeaf(
  HostedRouter router,
  LeafMode mode,
  String example,
  List<String> args,
) => runToCompletion(
  _dartExe,
  [
    'run',
    'example/$example',
    ...args,
    ...router.leafArgs(mode),
  ],
  workingDirectory: Directory.current.path,
  timeout: _runWait,
);

/// Waits until a subscriber on [key] is visible to a publisher elsewhere on
/// [router].
///
/// THE EXACT GATE, and the reason it exists is that the cheaper ones do not
/// answer the question. A spawned example's banner says its process started;
/// the router's `peersZid()` says the transport linked. Neither says the
/// subscriber's declaration has crossed the router -- and publishing before
/// it has loses the sample outright, because zenoh retains nothing for a
/// subscriber that was not there yet. A publisher on a third leaf reporting a
/// match IS that declaration having been propagated back, so this cannot pass
/// early.
///
/// The probe leaf publishes nothing. It exists only to be told.
Future<void> _awaitRoutedSubscriber(HostedRouter router, String key) async {
  final probe = await Session.open(config: router.leafConfig(LeafMode.client));
  final publisher = probe.declarePublisher(key);
  try {
    await awaitMatching(publisher.hasMatchingSubscribers, within: _readyWait);
  } finally {
    publisher.close();
    probe.close();
  }
}

/// Waits until a queryable on [key] answers a query routed through [router].
///
/// The queryable-side equivalent of [_awaitRoutedSubscriber], and it is a
/// LIVENESS leg as well as a gate: it returns only when a reply has actually
/// come back, so a cell that uses it before asserting an absence cannot be
/// asserting the absence of something that never worked.
///
/// Bounded by construction. Each attempt carries its own 500 ms query
/// timeout, which paces the loop, and the loop stops at [_readyWait].
Future<void> _awaitRoutedQueryable(HostedRouter router, String key) async {
  final probe = await Session.open(config: router.leafConfig(LeafMode.client));
  try {
    final deadline = DateTime.now().add(_readyWait);
    while (DateTime.now().isBefore(deadline)) {
      final replies = await probe
          .get(key, timeout: const Duration(milliseconds: 500))
          .toList();
      if (replies.any((reply) => reply.isOk)) return;
    }
    fail(
      'Timed out after ${_readyWait.inSeconds}s waiting for a queryable on '
      '"$key" to answer through the router on port ${router.port}.',
    );
  } finally {
    probe.close();
  }
}

/// Spawns [example] as a queryable peer leaf of [router], ready to answer.
///
/// Bundles the spawn with BOTH gates, because omitting the second one is
/// SILENT: the banner says the process started, and a query sent on that
/// alone races the declaration through the router, failing intermittently in
/// a way that reads as non-delivery. [_awaitRoutedQueryable] returns only
/// once a reply has actually come back, so it is a liveness leg as well as a
/// gate -- which is what lets the negative control below assert an absence
/// that means something.
Future<_Leaf> _spawnReadyQueryable(
  HostedRouter router,
  String example,
  String key,
  String payload,
) async {
  final queryable = await _spawnLeaf(router, LeafMode.peer, example, [
    '-k',
    key,
    '-p',
    payload,
  ]);
  await waitForReady(queryable.out, timeout: _readyWait);
  await _awaitRoutedQueryable(router, key);
  return queryable;
}

/// [path]'s lines, 1-based, with whole-line comments dropped.
Iterable<({int line, String text})> _codeLines(String path) sync* {
  final lines = File(path).readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('//')) continue;
    yield (line: i + 1, text: lines[i]);
  }
}

void main() {
  group('A spawned pair exchanges through one hosted router (TCP 19830)', () {
    late HostedRouter router;

    setUpAll(() async {
      router = await HostedRouter.open(_pubSubRouterPort);
    });

    tearDownAll(() => router.close());

    test('a spawned put crosses the router to a spawned subscriber', () async {
      // Counterpart of z_sub_cli_test.dart:37, which drives this same example
      // from an in-process session over a direct link. Here BOTH sides are
      // spawned examples, neither listens, and the putter is a client -- so
      // no path exists between them except through the router.
      const key = 'demo/routed/cli/sub';
      const payload = 'routed-cli-put';
      final expected = _receivedLine('PUT', key, payload);

      final sub = await _spawnLeaf(router, LeafMode.peer, 'z_sub.dart', [
        '-k',
        key,
      ]);
      await waitForReady(sub.out, timeout: _readyWait);

      // The router's own view, the second witness: the banner says the
      // process started, not that it attached to anything.
      await awaitCondition(
        () => router.peersZid().isNotEmpty,
        description: 'the router to report the spawned subscriber leaf',
        within: _readyWait,
      );
      await _awaitRoutedSubscriber(router, key);

      final put = await _runLeaf(router, LeafMode.client, 'z_put.dart', [
        '-k',
        key,
        '-p',
        payload,
      ]);
      expect(put.exitCode, isZero, reason: 'z_put stderr: ${put.stderr}');

      await waitForOutput(sub.out, expected, timeout: _readyWait);
      expect(
        sub.out.toString(),
        contains(expected),
        reason: 'subscriber stderr: ${sub.err}',
      );
    });
  });

  group('A spawned queryable answers through the router '
      '(TCP 19832, split 19831)', () {
    late HostedRouter router;
    late HostedRouter splitRouter;

    setUpAll(() async {
      router = await HostedRouter.open(_queryRouterPort);
      splitRouter = await HostedRouter.open(_splitRouterPort);
    });

    tearDownAll(() {
      splitRouter.close();
      router.close();
    });

    test(
      'a spawned queryable answers a spawned getter through the router',
      () async {
        // Counterpart of z_queryable_cli_test.dart:58, which queries the same
        // example from an in-process session over a direct link.
        const key = 'demo/routed/cli/q';
        const payload = 'routed-q-reply';

        final queryable = await _spawnReadyQueryable(
          router,
          'z_queryable.dart',
          key,
          payload,
        );

        final get = await _runLeaf(router, LeafMode.client, 'z_get.dart', [
          '-s',
          key,
          '-o',
          '5000',
        ]);

        expect(get.exitCode, isZero, reason: 'z_get stderr: ${get.stderr}');
        expect(get.stdout as String, contains(_replyLine(key, payload)));
        // ...and the queryable's own side observed a real query, so the reply
        // was an answer rather than something emitted unconditionally.
        expect(
          queryable.out.toString(),
          contains(">> [Queryable ] Received Query '$key"),
          reason: 'queryable stderr: ${queryable.err}',
        );
      },
    );

    test(
      'the same query across two unlinked routers returns no reply',
      () async {
        // THE NEGATIVE CONTROL. Same two examples, same flags, same roles; the
        // getter dials the OTHER router, which nothing links to this one.
        const key = 'demo/routed/cli/q-split';
        const payload = 'routed-split-reply';

        // READINESS FIRST, and as a LIVENESS leg rather than a banner:
        // _spawnReadyQueryable returns only once a probe getter on THIS router
        // has received the reply, so the zero below cannot be a queryable that
        // never worked.
        await _spawnReadyQueryable(router, 'z_queryable.dart', key, payload);

        // A second, independent reading that the two routers are unlinked: the
        // queryable leaf is on this one and nothing at all is on the other.
        expect(router.peersZid(), isNotEmpty);
        expect(splitRouter.peersZid(), isEmpty);
        expect(splitRouter.zid, isNot(equals(router.zid)));

        final get = await _runLeaf(splitRouter, LeafMode.client, 'z_get.dart', [
          '-s',
          key,
          '-o',
          '3000',
        ]);

        // The absence window is the getter's OWN query timeout, so this is a
        // bounded wait rather than a chosen sleep, and the process completing
        // on its own is the proof that it ran at all.
        expect(get.exitCode, isZero);
        final out = get.stdout as String;
        expect(out, contains("Sending Query '$key'"));
        expect(out, isNot(contains('>> Received (')));
      },
    );

    test(
      'the channel queryable answers a routed getter from its recv loop',
      () async {
        // Counterpart of z_queryable_with_channels_cli_test.dart:15. Its claim
        // is that the reply comes out of the example's own recv loop, which the
        // example's Received Query line is the evidence for.
        const key = 'demo/routed/cli/qwc';
        const payload = 'routed-qwc-reply';

        final queryable = await _spawnReadyQueryable(
          router,
          'z_queryable_with_channels.dart',
          key,
          payload,
        );

        final get = await _runLeaf(router, LeafMode.client, 'z_get.dart', [
          '-s',
          key,
          '-o',
          '5000',
        ]);

        expect(get.exitCode, isZero, reason: 'z_get stderr: ${get.stderr}');
        expect(get.stdout as String, contains(_replyLine(key, payload)));
        await waitForOutput(
          queryable.out,
          'Received Query',
          timeout: _readyWait,
        );
        expect(
          queryable.out.toString(),
          contains(">> [Queryable ] Received Query '$key"),
        );
      },
    );
  });

  group('A spawned storage stores and serves through the router (TCP 19833)', () {
    late HostedRouter router;

    setUpAll(() async {
      router = await HostedRouter.open(_storageRouterPort);
    });

    tearDownAll(() => router.close());

    test(
      'a spawned storage stores a routed put and serves a routed query',
      () async {
        // Counterpart of z_storage_cli_test.dart:131. Three leaves, and the
        // storage is the only peer: the putter and the getter are clients, so
        // neither can reach it except through the router.
        const keyExpr = 'demo/routed/cli/store/**';
        const key = 'demo/routed/cli/store/key1';
        const value = 'routed-value1';

        final storage = await _spawnLeaf(
          router,
          LeafMode.peer,
          'z_storage.dart',
          ['-k', keyExpr],
        );
        await waitForReady(storage.out, timeout: _readyWait);
        await _awaitRoutedSubscriber(router, key);

        final put = await _runLeaf(router, LeafMode.client, 'z_put.dart', [
          '-k',
          key,
          '-p',
          value,
        ]);
        expect(put.exitCode, isZero, reason: 'z_put stderr: ${put.stderr}');

        // The original sleeps 2 s for "propagation" here. This waits for the
        // storage to SAY it stored the value, which is the condition the query
        // below actually depends on.
        await waitForOutput(
          storage.out,
          _receivedLine('PUT', key, value),
          timeout: _readyWait,
        );

        await _awaitRoutedQueryable(router, keyExpr);
        final get = await _runLeaf(router, LeafMode.client, 'z_get.dart', [
          '-s',
          keyExpr,
          '-o',
          '5000',
        ]);

        expect(get.exitCode, isZero, reason: 'z_get stderr: ${get.stderr}');
        expect(
          get.stdout as String,
          contains(_replyLine(key, value)),
          reason: 'storage stderr: ${storage.err}',
        );
      },
    );

    test(
      'a routed delete removes the entry and the routed query omits it',
      () async {
        // Counterpart of z_storage_cli_test.dart:203. The original deletes from
        // an in-process session; here the delete is our own `z_delete` example
        // on a client leaf, so the DELETE crosses the router exactly as the PUT
        // did.
        const keyExpr = 'demo/routed/cli/store2/**';
        const key1 = 'demo/routed/cli/store2/key1';
        const key2 = 'demo/routed/cli/store2/key2';
        const value1 = 'routed-val1';
        const value2 = 'routed-val2';

        final storage = await _spawnLeaf(
          router,
          LeafMode.peer,
          'z_storage.dart',
          ['-k', keyExpr],
        );
        await waitForReady(storage.out, timeout: _readyWait);
        await _awaitRoutedSubscriber(router, key1);

        final put1 = await _runLeaf(router, LeafMode.client, 'z_put.dart', [
          '-k',
          key1,
          '-p',
          value1,
        ]);
        expect(put1.exitCode, isZero, reason: 'z_put stderr: ${put1.stderr}');
        final put2 = await _runLeaf(router, LeafMode.client, 'z_put.dart', [
          '-k',
          key2,
          '-p',
          value2,
        ]);
        expect(put2.exitCode, isZero, reason: 'z_put stderr: ${put2.stderr}');

        await waitForOutput(
          storage.out,
          _receivedLine('PUT', key1, value1),
          timeout: _readyWait,
        );
        await waitForOutput(
          storage.out,
          _receivedLine('PUT', key2, value2),
          timeout: _readyWait,
        );

        final del = await _runLeaf(router, LeafMode.client, 'z_delete.dart', [
          '-k',
          key1,
        ]);
        expect(del.exitCode, isZero, reason: 'z_delete stderr: ${del.stderr}');
        await waitForOutput(
          storage.out,
          _receivedLine('DELETE', key1, ''),
          timeout: _readyWait,
        );

        await _awaitRoutedQueryable(router, keyExpr);
        final get = await _runLeaf(router, LeafMode.client, 'z_get.dart', [
          '-s',
          keyExpr,
          '-o',
          '5000',
        ]);

        expect(get.exitCode, isZero, reason: 'z_get stderr: ${get.stderr}');
        final out = get.stdout as String;
        // The survivor came back through the router...
        expect(out, contains(_replyLine(key2, value2)));
        // ...and the deleted one did not, which is the claim.
        expect(out, isNot(contains(value1)));
      },
    );
  });

  group('A spawned pull subscriber is served through the router (TCP 19834)', () {
    late HostedRouter router;

    setUpAll(() async {
      router = await HostedRouter.open(_pullRouterPort);
    });

    tearDownAll(() => router.close());

    test(
      "a pull subscriber's buffered sample survives the router hop",
      () async {
        // Counterpart of z_pull_cli_test.dart:77. THE CLAIM IS ROUTED ARRIVAL.
        // The ring's one-sample-per-keypress granularity is a local property of
        // the channel, not of the path, and it stays where it is -- in
        // z_pull_cli_test.dart:155, which this cell does not restate.
        const key = 'demo/routed/cli/pull';
        const payload = 'routed-pull-payload';
        final expected = _receivedLine('PUT', key, payload);

        final pull = await _spawnLeaf(router, LeafMode.peer, 'z_pull.dart', [
          '-k',
          key,
        ]);
        await waitForOutput(pull.out, _pullReady, timeout: _readyWait);
        await _awaitRoutedSubscriber(router, key);

        final put = await _runLeaf(router, LeafMode.client, 'z_put.dart', [
          '-k',
          key,
          '-p',
          payload,
        ]);
        expect(put.exitCode, isZero, reason: 'z_put stderr: ${put.stderr}');

        // The example prints nothing until it is ASKED for a sample: one
        // try_recv per input byte, and an empty channel prints nothing at all.
        // So the nudge is a periodic timer while the bounded poll below watches
        // for the line -- which keeps the wait a wait-for-condition, returning
        // the moment the sample lands instead of after a chosen interval.
        final nudger = Timer.periodic(const Duration(milliseconds: 100), (t) {
          try {
            pull.process.stdin.writeln();
          } on Object catch (_) {
            t.cancel();
          }
        });
        addTearDown(nudger.cancel);

        await awaitCondition(
          () => pull.out.toString().contains(expected),
          description: 'the routed pull subscriber to print the pulled sample',
          within: _readyWait,
        );
        nudger.cancel();

        expect(
          pull.out.toString(),
          contains(expected),
          reason: 'pull stderr: ${pull.err}',
        );
      },
    );
  });

  group('A non-blocking get completes through the router (TCP 19835)', () {
    late HostedRouter router;

    setUpAll(() async {
      router = await HostedRouter.open(_nonBlockingRouterPort);
    });

    tearDownAll(() => router.close());

    test('a non-blocking get through the router reports its completion '
        'honestly', () async {
      // Counterpart of z_non_blocking_get_cli_test.dart:47. Two arms, because
      // "honestly" is the whole point of the example: its loop exits on the
      // channel's DISCONNECTED arm -- the query completed, with however many
      // replies -- and never on its timeout, which is RecvEmpty's "nothing
      // yet, ask again". A loop that confused the two would still LOOK right
      // on the answered arm.
      const key = 'demo/routed/cli/nbg';
      const payload = 'routed-nbg-reply';

      await _spawnReadyQueryable(router, 'z_queryable.dart', key, payload);

      // Arm one: a reply exists, and it crossed the router.
      final answered = await _runLeaf(
        router,
        LeafMode.client,
        'z_non_blocking_get.dart',
        ['-s', key, '-o', '5000'],
      );
      expect(
        answered.exitCode,
        isZero,
        reason: 'z_non_blocking_get stderr: ${answered.stderr}',
      );
      expect(answered.stdout as String, contains(_replyLine(key, payload)));

      // Arm two: nothing answers, through the same router. The query must
      // COMPLETE with none rather than sit out its 20 s timeout.
      final started = DateTime.now();
      final unanswered = await _runLeaf(
        router,
        LeafMode.client,
        'z_non_blocking_get.dart',
        ['-s', 'demo/routed/cli/nbg-nobody/**', '-o', '20000'],
      );
      final elapsed = DateTime.now().difference(started);

      expect(
        unanswered.exitCode,
        isZero,
        reason: 'z_non_blocking_get stderr: ${unanswered.stderr}',
      );
      final out = unanswered.stdout as String;
      expect(out, contains('Sending Query'));
      expect(out, isNot(contains('>> Received (')));
      expect(
        elapsed.inSeconds,
        lessThan(15),
        reason: 'the exit condition must be the disconnect arm, not the clock',
      );
    });
  });

  group(
    'A spawned advanced pair exchanges through the router (TCP 19836)',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late HostedRouter router;

      setUpAll(() async {
        router = await HostedRouter.open(_advancedRouterPort);
      });

      tearDownAll(() => router.close());

      test(
        'a spawned advanced subscriber recovers history through the router',
        () async {
          // Counterpart of z_advanced_sub_cli_test.dart:44, which runs the same
          // pair over a direct link. The recovery is itself a query, so this
          // cell puts the router in the path of the history query as well as of
          // the live samples.
          const key = 'demo/routed/cli/adv';

          final pub = await _spawnLeaf(
            router,
            LeafMode.peer,
            'z_advanced_pub.dart',
            ['-k', key, '-i', '5'],
          );
          // The original's gate, for the original's reason: `[   2]` means
          // samples [0]..[2] are published and inside the 5-sample cache, so
          // [0] cannot have been evicted by the time the subscriber attaches.
          // The index is padded to width 4, as canon's sprintf does.
          await waitForOutput(pub.out, "'[   2] ", timeout: _readyWait);

          final sub = await _spawnLeaf(
            router,
            LeafMode.client,
            'z_advanced_sub.dart',
            ['-k', 'demo/routed/cli/**'],
          );
          await waitForReady(sub.out, timeout: _readyWait);

          // `[0]` is the discriminator, and it is what the claim is about: the
          // publisher published it before this subscriber existed, so it can
          // only have come from the history cache. The publisher also puts
          // every second, so a subscriber with a completely broken history path
          // would still show a Received PUT within ~1 s.
          await waitForOutput(sub.out, "'[   0] ", timeout: _readyWait);
          expect(
            sub.out.toString(),
            contains('Received PUT'),
            reason: 'advanced sub stderr: ${sub.err}',
          );
          expect(sub.out.toString(), contains('[   0] '));
        },
      );
    },
  );

  group('The router hop did not become a fixed sleep', () {
    test('every wait in this file is a bounded wait-for-condition', () {
      // [inspection], and it is about THIS file. The original CLI groups ride
      // fixed sleeps -- 2 s for "propagation", 3 s for a listener to bind,
      // 2 s for a connection to negotiate. A router hop lengthens
      // convergence, so inheriting one of those would be inheriting a race
      // and making it worse; and a sleep long enough to be safe costs the
      // suite that time on every run, forever.
      //
      // Written as a scan rather than as a note in a report because a note is
      // true on the day it is written and nothing re-checks it. This fails
      // the moment a cell added later reaches for a sleep.
      //
      // The needles are assembled from [_paren] rather than spelled out, so
      // this cell cannot match its own definition -- see [_paren].
      const sleepShapes = ['.delayed$_paren', 'sleep$_paren', _settleNeedle];
      const boundedWaits = [
        'awaitCondition$_paren',
        'awaitMatching$_paren',
        'waitForOutput$_paren',
        'waitForReady$_paren',
      ];

      final sleeps = <String>[];
      var bounded = 0;
      for (final line in _codeLines(_selfPath)) {
        for (final shape in sleepShapes) {
          if (line.text.contains(shape)) {
            sleeps.add('$_selfPath:${line.line}: ${line.text.trim()}');
          }
        }
        for (final wait in boundedWaits) {
          if (line.text.contains(wait)) bounded++;
        }
      }

      expect(
        sleeps,
        isEmpty,
        reason:
            'A routed CLI cell waited by sleeping. Every wait here has a '
            'condition to poll: the process own readiness marker, the '
            "router's own view of its leaves, a probe publisher seeing the "
            'subscriber, or a probe getter receiving the reply. The helper '
            'settle exists for the case where no condition can be polled, '
            'and this file has one everywhere.\n'
            '${sleeps.join('\n')}',
      );
      // The control for the assertion above it: a scan that found no waits at
      // all would report exactly the same empty sleep list.
      expect(
        bounded,
        greaterThan(10),
        reason:
            'the scan found almost no bounded waits, so the clean result '
            'above it is vacuous rather than earned.',
      );
    });
  });
}
