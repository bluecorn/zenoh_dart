// The routed topology: the one place that knows what "a router in the path"
// means, for every routed counterpart in the suite.
//
// THE OBSERVABLE, AND WHY IT TAKES THREE THINGS RATHER THAN ONE
//
// Pointing two sessions at a router satisfies "a router endpoint is
// configured" while the sample never touches it. In the default configuration
// peers find each other by gossip and link DIRECTLY, so the router sits
// beside the path instead of in it -- and the green that results is
// indistinguishable from the no-router case. Measured 2026-09-07: a
// shared-memory publication between two peers with a router up and gossip ON
// arrives carrying exactly the tag it carries when no router is running at
// all.
//
// So a routed leaf carries THREE things, and each one is load-bearing:
//
//   1. only the router's endpoint -- never a listen endpoint of its own;
//   2. multicast scouting off AND gossip off, so no direct link can form;
//   3. at least one leaf of the pair in `client` mode.
//
// The third is the one that is easy to drop, and dropping it is why the first
// statement of this shape delivered nothing at all. Two PEERS that cannot
// gossip are not routed to each other by a router -- they are simply
// isolated. Measured, with the subscriber's readiness confirmed beside every
// zero: peer to peer delivers 0 as a one-shot put, 0 with a long-running
// publisher, and 0 with `routing/peer/mode:"linkstate"` set on both; while
// client to peer, peer to client and client to client all deliver.
//
// With all three in place DELIVERY ITSELF is the observable: no direct
// leaf-to-leaf link can form, so anything that arrives was carried by the
// router. Cells built on this helper pair that with a SPLIT control -- the
// same two leaves, the same flags, attached to two unlinked routers -- which
// must observe nothing.
//
// WHY GOSSIP-OFF IS THE MECHANISM AND NOT HYGIENE
//
// It is what makes the negative controls mean anything. With gossip on, the
// split control would still deliver, because the two leaves would find each
// other directly and neither router would be involved either way.
//
// WHAT THIS HELPER DELIBERATELY DOES NOT REACH FOR
//
// The router is a session this process opens -- a zenoh session in
// `mode: "router"` IS a router -- so nothing here needs an external router
// binary, a fetched release artifact, or an environment variable naming one.
// The default suite therefore acquires no new dependency from any cell built
// on this helper: it runs exactly as it does for someone who has fetched
// nothing.
//
// PORTS
//
// This unit owns 19800-19899, allocated above a corpus ceiling measured at
// 19765 by three mechanically different instruments. The interop tier takes
// 19800-19809; each default-suite routed file takes a block of ten from
// 19810 up and states its block at the top of the file.
import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

/// The lowest port this unit may bind, and the highest.
///
/// Enforced rather than documented: a routed cell that strayed below the band
/// would collide with the ~189 endpoint literals the rest of the corpus
/// already holds, and the collision would present as a delivery red rather
/// than as an address clash.
const routedPortFloor = 19800;

/// The highest port this unit may bind. See [routedPortFloor].
const routedPortCeiling = 19899;

/// The ceiling for this helper's bounded waits, unless a caller states its
/// own.
///
/// A router hop lengthens convergence, so this is longer than the 5 s the
/// direct-path pollers use. It is a CEILING, not a delay: every wait here
/// returns as soon as its condition holds.
const routedWaitTimeout = Duration(seconds: 10);

/// The mode a leaf session runs in.
enum LeafMode {
  /// Attaches to exactly one router and never links to another leaf.
  client('client'),

  /// Would ordinarily link directly to other peers; under this helper's
  /// suppression it reaches them only through the router.
  peer('peer'),

  /// A router.
  ///
  /// Present so [RoutedPair] can refuse a pair containing no client -- a
  /// configuration that is measured to deliver nothing, and which would
  /// otherwise be spelled without an error.
  router('router');

  const LeafMode(this.wireName);

  /// The value zenoh's `mode` key and the examples' `-m` flag both take.
  final String wireName;
}

/// The measured ground for the client clause, quoted wherever it is enforced.
const _noClientReason =
    'a routed pair needs at least one leaf in client mode: two peers behind a '
    'router with multicast and gossip both disabled are ISOLATED, not routed '
    '-- measured 2026-09-07 as zero delivery in three arms, with the '
    "subscriber's readiness confirmed beside every zero";

/// The measured ground for the suppression clause.
const _discoveryReason =
    'a routed leaf must have multicast scouting AND gossip disabled: with '
    'either one enabled the leaves link DIRECTLY and the router is beside the '
    'path rather than in it, which produces a green indistinguishable from '
    'the no-router case';

/// The two roles a routed exchange is built from, validated on construction.
///
/// Its only job is to refuse a pair that cannot be routed. Construct one
/// before opening either leaf, so the refusal lands before any session
/// exists.
class RoutedPair {
  /// Refuses unless at least one of [a] and [b] is [LeafMode.client].
  RoutedPair(this.a, this.b) {
    if (a != LeafMode.client && b != LeafMode.client) {
      throw ArgumentError.value(
        '${a.wireName}/${b.wireName}',
        'RoutedPair',
        _noClientReason,
      );
    }
  }

  /// One side's mode.
  final LeafMode a;

  /// The other side's mode.
  final LeafMode b;
}

/// A router this test process hosts, for leaves to attach to.
///
/// Open one per group and close it in the group's teardown. Cells that need a
/// negative control open a SECOND one and attach one leaf to it: the two are
/// unlinked, so nothing crosses between them.
class HostedRouter {
  HostedRouter._(this.session, this.port);

  /// Opens a router session listening on [port].
  ///
  /// Discovery is suppressed on the router as well as on its leaves, so every
  /// relationship a cell asserts is one the configured endpoints created.
  static Future<HostedRouter> open(int port) async {
    _requireUnitPort(port, 'port');
    final config = Config()
      ..insertJson5('mode', '"${LeafMode.router.wireName}"')
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false');
    final session = await Session.open(config: config);
    return HostedRouter._(session, port);
  }

  /// The router's own session. Read it for `peersZid()` and `zid`; do not
  /// publish or subscribe on it, or the exchange stops being routed.
  final Session session;

  /// The TCP port this router listens on.
  final int port;

  /// This router's zid — what an attached leaf reports from `routersZid()`.
  ZenohId get zid => session.zid;

  /// The router's own view of its attached PEER leaves.
  ///
  /// Client leaves do not appear here: a router partitions its view by role,
  /// and that asymmetry is canon-verified rather than incidental.
  List<ZenohId> peersZid() => session.peersZid();

  /// The router's own view of OTHER routers.
  ///
  /// Exposed for symmetry with [peersZid], and because "a router knows no
  /// other router" is a real assertion in a single-router topology: without
  /// it, a cell reading only `peersZid` cannot tell a correctly-partitioned
  /// view from one that simply returns everything it knows in one list.
  List<ZenohId> routersZid() => session.routersZid();

  /// The four things every routed leaf carries, in one place.
  ///
  /// ⭐ **Both leaf surfaces render THIS**, rather than each spelling the four
  /// out independently. The in-process form and the spawned form must express
  /// the same topology or a cell and its CLI sibling silently test different
  /// things while reading alike — and a divergence between two hand-written
  /// lists is invisible until something goes red for an unrelated reason.
  /// Making the spec the single source lets a cell ASSERT the parity instead
  /// of a reader having to eyeball it.
  ({String mode, String endpoint, bool multicastOff, bool gossipOff}) leafSpec(
    LeafMode mode,
  ) => (
    mode: mode.wireName,
    endpoint: 'tcp/127.0.0.1:$port',
    multicastOff: true,
    gossipOff: true,
  );

  /// A fresh leaf [Config] for an in-process leaf attached to this router.
  ///
  /// Refuses to emit a configuration with either discovery mechanism left on
  /// — see [_discoveryReason]. The two flags exist so that refusal is
  /// reachable from a cell, not so that a caller can turn them off.
  Config leafConfig(
    LeafMode mode, {
    bool disableMulticast = true,
    bool disableGossip = true,
  }) {
    _requireSuppressed(
      disableMulticast: disableMulticast,
      disableGossip: disableGossip,
    );
    final spec = leafSpec(mode);
    return Config()
      ..insertJson5('mode', '"${spec.mode}"')
      ..insertJson5('connect/endpoints', '["${spec.endpoint}"]')
      ..insertJson5('scouting/multicast/enabled', '${!spec.multicastOff}')
      ..insertJson5('scouting/gossip/enabled', '${!spec.gossipOff}');
  }

  /// The CLI flag block for a SPAWNED leaf attached to this router.
  ///
  /// Expresses the same four things [leafConfig] does, through the flag
  /// surface the examples parse. The two forms are asserted field-for-field
  /// against each other in this helper's own tests, because a divergence
  /// between them would make an in-process cell and its spawned sibling test
  /// different topologies while reading identically.
  List<String> leafArgs(
    LeafMode mode, {
    bool disableMulticast = true,
    bool disableGossip = true,
  }) {
    _requireSuppressed(
      disableMulticast: disableMulticast,
      disableGossip: disableGossip,
    );
    final spec = leafSpec(mode);
    return [
      '-m',
      spec.mode,
      '-e',
      spec.endpoint,
      if (spec.multicastOff) '--no-multicast-scouting',
      if (spec.gossipOff) ...['--cfg', 'scouting/gossip/enabled:false'],
    ];
  }

  /// Waits until [leaf] reports this router in its own `routersZid()`.
  ///
  /// The leaf's view, so it works for a client leaf as well as a peer one.
  /// This is the readiness gate a routed cell uses instead of a fixed sleep:
  /// it asserts the attachment the cell depends on, rather than the machine's
  /// speed.
  Future<void> awaitAttached(
    Session leaf, {
    Duration within = routedWaitTimeout,
  }) => awaitCondition(
    () => leaf.routersZid().any((id) => id == zid),
    description: 'a leaf to report the hosted router on port $port',
    within: within,
  );

  /// Waits until this router's own `peersZid()` contains [leafZid].
  ///
  /// The second, independent witness that an attachment is real and not
  /// merely configured. Peer leaves only — see [peersZid].
  Future<void> awaitPeerLeaf(
    ZenohId leafZid, {
    Duration within = routedWaitTimeout,
  }) => awaitCondition(
    () => peersZid().any((id) => id == leafZid),
    description: 'the hosted router on port $port to report a peer leaf',
    within: within,
  );

  /// Closes the router session, releasing [port].
  void close() => session.close();
}

/// How long to let a fresh declaration propagate before publishing at it.
///
/// ⚠️ **This is a SETTLE, and it is deliberately a sleep.** The distinction
/// matters and it is easy to get wrong here: `awaitAttached` and
/// [HostedRouter.awaitPeerLeaf] witness that the **transport** linked, which
/// is NOT the same as the subscriber's declaration having reached the router.
/// Gate on those two and publish immediately and the sample can be emitted
/// before anything is subscribed to it — and zenoh does not retain it, so the
/// cell fails intermittently for a reason that looks like non-delivery.
///
/// Propagation has no condition this side can poll, and the project's own rule
/// (`helpers/poll.dart`) is that settle time "has no condition to poll and
/// should stay a sleep". The corpus settles 1 s on a direct link; a routed
/// pair carries one extra hop, so this is longer.
///
/// ▶ **Where a real condition EXISTS, poll it instead** — see [awaitMatching],
/// which is exact and should be preferred whenever a Publisher is in hand.
const routedDeclarationSettle = Duration(seconds: 2);

/// Lets a fresh declaration propagate through the router. See
/// [routedDeclarationSettle] for why this is a sleep and not a poll.
Future<void> settleForDeclaration() =>
    Future<void>.delayed(routedDeclarationSettle);

/// Waits until a publisher reports a matching subscriber.
///
/// ⭐ **The exact form of the readiness this unit actually needs**, and strictly
/// better than [settleForDeclaration] wherever it can be used: a publisher
/// reporting a match IS the router having propagated the subscriber's
/// declaration back to it. It cannot pass early, and it does not spend time it
/// does not need.
///
/// ⚠️ **Takes the PREDICATE, not a Publisher, and the difference is not
/// stylistic.** `AdvancedPublisher` does not implement `Publisher` — it
/// `implements Finalizable` independently — but it exposes the same
/// `hasMatchingSubscribers()`. Typed to `Publisher`, this helper silently
/// excluded every advanced counterpart and pushed them onto
/// [settleForDeclaration], trading an exact gate for a hopeful one for no
/// reason anybody had checked. Pass the tear-off:
/// `awaitMatching(publisher.hasMatchingSubscribers)`.
Future<void> awaitMatching(
  bool Function() hasMatchingSubscribers, {
  Duration within = routedWaitTimeout,
}) => awaitCondition(
  hasMatchingSubscribers,
  description: 'the publisher to see a matching subscriber through the router',
  within: within,
);

/// Waits until a SUBSCRIBER on [key] is reachable through [router].
///
/// ⭐ **The exact gate, and the reason it exists is that the cheaper ones do
/// not answer the question.** A spawned example's banner says its process
/// started. [HostedRouter.awaitPeerLeaf] says the transport linked. **Neither
/// says the subscriber's declaration has crossed the router** — and publishing
/// before it has loses the sample outright, because zenoh retains nothing for
/// a subscriber that was not there yet. The cell then fails intermittently,
/// wearing the costume of non-delivery.
///
/// A publisher on a THIRD leaf reporting a match IS that declaration having
/// been propagated back through the router, so this cannot pass early. The
/// probe leaf publishes nothing; it exists only to be told.
///
/// *(Originated in the dispatched Slice 10, which reached zero settles in 863
/// lines with it, and is promoted here so later counterparts do not reinvent
/// it.)*
Future<void> awaitRoutedSubscriber(
  HostedRouter router,
  String key, {
  Duration within = routedWaitTimeout,
}) async {
  final probe = await Session.open(config: router.leafConfig(LeafMode.client));
  final publisher = probe.declarePublisher(key);
  try {
    await awaitMatching(publisher.hasMatchingSubscribers, within: within);
  } finally {
    publisher.close();
    probe.close();
  }
}

/// Waits until a QUERYABLE on [key] answers through [router].
///
/// The dual of [awaitRoutedSubscriber], and exact for the same reason: only a
/// working routed query/reply path can satisfy it. Fails with a named bound
/// rather than hanging.
///
/// ⛔⛔ **NOT FOR A PULL QUERYABLE, and the failure is double.** A
/// `declarePullQueryable` replies only when the test drains it, so a gate
/// waiting for an automatic reply can NEVER succeed against one — and the
/// probe's query is not free: it OCCUPIES A SLOT in the channel, which for a
/// bounded one is the carrier the cell is about to assert over. That is the
/// same shape as the readiness trap measured in the liveliness counterparts: a
/// gate that acts on the carrier under test is part of the observation.
/// ▶ For a pull queryable, gate by completing the round trip yourself — send
/// one get, drain it, reply — which proves the path and leaves the channel
/// empty. `routed_backpressure_test.dart` is the worked example.
Future<void> awaitRoutedQueryable(
  HostedRouter router,
  String key, {
  Duration within = routedWaitTimeout,
}) async {
  final probe = await Session.open(config: router.leafConfig(LeafMode.client));
  try {
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      final replies = await probe
          .get(key, timeout: const Duration(milliseconds: 500))
          .toList();
      if (replies.any((reply) => reply.isOk)) return;
    }
    fail(
      'Timed out after ${within.inMilliseconds}ms waiting for a queryable on '
      '"$key" to answer through the hosted router on port ${router.port}.',
    );
  } finally {
    probe.close();
  }
}

/// Polls until [condition] holds; fails with the bound if it never does.
///
/// The only wait this unit's cells use. It has a ceiling by construction, so
/// a routed cell whose sample never arrives fails naming what it was waiting
/// for instead of hanging the serial suite — which is the most expensive
/// failure available to a unit whose most likely red is "nothing arrived".
Future<void> awaitCondition(
  bool Function() condition, {
  required String description,
  Duration within = routedWaitTimeout,
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail(
    'Timed out after ${within.inMilliseconds}ms waiting for $description.',
  );
}

void _requireSuppressed({
  required bool disableMulticast,
  required bool disableGossip,
}) {
  if (!disableMulticast || !disableGossip) {
    throw ArgumentError.value(
      'multicast=${!disableMulticast} gossip=${!disableGossip}',
      'leaf discovery',
      _discoveryReason,
    );
  }
}

void _requireUnitPort(int port, String name) {
  if (port < routedPortFloor || port > routedPortCeiling) {
    throw ArgumentError.value(
      port,
      name,
      'routed cells bind $routedPortFloor-$routedPortCeiling only, above the '
      'corpus ceiling measured at 19765',
    );
  }
}
