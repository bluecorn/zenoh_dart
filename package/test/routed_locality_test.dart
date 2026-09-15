@Timeout(Duration(minutes: 3))
library;

// Origin filtering, with a router actually in the path.
//
// Ten cells in the default suite certify that `allowedOrigin` discriminates
// between same-session and remote traffic across five declaration paths.
// Every one of them certifies it over a DIRECT peer link -- the one shape a
// deployment never uses, and the shape in which "remote" can only ever mean
// "the other end of a single hop". This file adds their routed counterparts,
// where "remote" means "carried by a router". Nothing here replaces anything:
// all ten originals stay exactly where they are, unedited, and keep
// certifying the direct path.
//
// WHAT THIS FILE MEASURED, stated first because it is the slice's open
// question: ORIGIN CLASSIFICATION SURVIVES THE ROUTER HOP UNCHANGED, on all
// five paths. A sample that crossed the router is classified remote, a
// same-session publication is still classified local, and every reading below
// matches its direct-path original leg for leg. The question was live rather
// than rhetorical: `allowedOrigin` is a per-sample path-dependent tag,
// structurally the same as the shared-memory backing tag, and that one is
// MEASURED in this unit to change across the hop (a publication that arrives
// [SHM (MUT)] on a direct link arrives [RAW] through a router). This tag does
// not.
//
// THE ORIGINALS, AND THE COUNTERPART CARRYING EACH CLAIM
//
// Every original lives in test/locality_declaration_test.dart. Five groups,
// two cells each. The group line is given for every row because five of the
// ten cells share the single name "allowedOrigin discriminates in all three
// modes" and the group is the only thing that tells them apart. Every
// counterpart below is named so that its OWN name identifies its declaration
// family, group or no group: a filter, a CI line or a flake log then names
// the exact cell rather than a family of five.
//
//   group "declareSubscriber allowedOrigin (TCP 18910)" at :53
//     :97  "allowedOrigin discriminates in all three modes"
//          (assertions :98, :104, :108)
//       -> group "declareSubscriber allowedOrigin, routed":
//          "declareSubscriber discriminates in all three modes"
//     :114 "an omitted allowedOrigin resolves to canon ANY" (assertion :115)
//       -> group "declareSubscriber allowedOrigin, routed":
//          "declareSubscriber omitting allowedOrigin is canon ANY"
//
//   group "declareBackgroundSubscriber allowedOrigin (TCP 18911)" at :132
//     :173 "allowedOrigin discriminates in all three modes"
//          (assertions :174, :179, :183)
//       -> group "declareBackgroundSubscriber allowedOrigin, routed":
//          "declareBackgroundSubscriber discriminates in all three modes"
//     :189 "an omitted allowedOrigin resolves to canon ANY" (assertion :190)
//       -> group "declareBackgroundSubscriber allowedOrigin, routed":
//          "declareBackgroundSubscriber omitting allowedOrigin is canon ANY"
//
//   group "declarePullSubscriber allowedOrigin (TCP 18912)" at :197
//     :240 "allowedOrigin discriminates in all three modes"
//          (assertions :241, :246, :250)
//       -> group "declarePullSubscriber allowedOrigin, routed":
//          "declarePullSubscriber discriminates in all three modes"
//     :256 "an omitted allowedOrigin resolves to canon ANY" (assertion :257)
//       -> group "declarePullSubscriber allowedOrigin, routed":
//          "declarePullSubscriber omitting allowedOrigin is canon ANY"
//
//   group "declareQueryable allowedOrigin (TCP 18913)" at :264
//     :305 "allowedOrigin discriminates in all three modes"
//          (assertions :309, :316, :320)
//       -> group "declareQueryable allowedOrigin, routed":
//          "declareQueryable discriminates in all three modes"
//     :326 "an omitted allowedOrigin resolves to canon ANY" (assertion :327)
//       -> group "declareQueryable allowedOrigin, routed":
//          "declareQueryable omitting allowedOrigin is canon ANY"
//
//   group "declareBackgroundQueryable allowedOrigin (TCP 18914)" at :334
//     :378 "allowedOrigin discriminates in all three modes"
//          (assertions :379, :384, :388)
//       -> group "declareBackgroundQueryable allowedOrigin, routed":
//          "declareBackgroundQueryable discriminates in all three modes"
//     :394 "an omitted allowedOrigin resolves to canon ANY" (assertion :395)
//       -> group "declareBackgroundQueryable allowedOrigin, routed":
//          "declareBackgroundQueryable omitting allowedOrigin is canon ANY"
//
//   :401 "a delivered query is still fully replyable and disposable"
//        (assertions :424, :425, :426) is OUTSIDE the ten, and it does carry
//        traffic, so it is counterparted anyway
//       -> group "declareBackgroundQueryable allowedOrigin, routed":
//          "a query delivered through the router is still fully replyable"
//
// TWO ORIGINALS IN THAT FILE GET NO COUNTERPART, each for a stated reason:
//
//   :121 "the failure path still throws and drops the closure once" -- a
//   synchronous refusal of an invalid key expression. It opens nothing,
//   sends nothing and observes nothing; there is no path for a router to sit
//   in.
//
//   :431 "declareLivelinessSubscriber gains no allowedOrigin" -- it reads
//   lib/src/session.dart as text, so it is topology-independent by
//   construction. It is also the carve-out that keeps liveliness out of this
//   family entirely: canon's `z_liveliness_subscriber_options_t` carries only
//   `history`, so there is no origin filter on that path to route.
//
// WHY THE ROUTER IS REALLY IN THE PATH
//
// Pointing two sessions at a router is not routing them. Peers find each
// other by gossip and link DIRECTLY, so the router sits beside the path and
// the green is indistinguishable from the no-router case. Every leaf below is
// built by helpers/routed_topology.dart, which carries the three things that
// make the difference real: the router's endpoint only, both discovery
// mechanisms off, and at least one leaf in client mode.
//
// THE WITNESS, AND WHY EVERY PATTERN CARRIES ONE
//
// Each cell declares the entity under test on leaf B and then an UNRESTRICTED
// twin of it on the same leaf and the same key expression. That twin is not
// decoration; it does three jobs no other construct here can do.
//
//   1. It makes the readiness EXACT for all three modes. The obvious gate --
//      a publisher on leaf A reporting a match -- is unreachable for a
//      `sessionLocal` declaration, because canon never advertises one beyond
//      its own session. That is measured rather than assumed, by the two
//      "never advertised" cells below, and it is exactly why a gate keyed on
//      the entity under test would hang for one of the three modes it has to
//      cover.
//   2. It makes every ABSENCE non-vacuous. A zero on a restricted entity
//      reads identically whether the filter rejected the sample or the sample
//      never arrived. The witness receives the very put the restricted entity
//      must not, on the same key, in the same session, at the same instant --
//      so the zero is attributable to the filter and to nothing else.
//   3. It is what lets this file assert an absence with NO sleep at all. See
//      the marker anchor below.
//
// Order matters and is load-bearing: the restricted entity is always declared
// FIRST. Declarations leave a session in order on one transport, so a gate
// satisfied by the witness is satisfied strictly after the restricted
// entity's own declaration had already gone (or had been suppressed).
//
// THE MARKER ANCHOR -- how an absence is read without a settle
//
// After both sources have published their payload, each publishes a second,
// distinct MARKER. The cell then waits until the witness holds all four. On
// the receiving session both entities are fed from the same native dispatch
// pass, so once a LATER message from a source has been observed, every
// EARLIER message from that source has already been posted to every port that
// was going to get it. Reading the restricted entity at that point is
// therefore exact: an admitted sample is present, a filtered one is provably
// absent rather than merely late. No fixed sleep is inherited and none is
// added.
//
// The markers are INSURANCE and are deliberately kept even though removing
// them was measured NOT to turn any cell red on this host: the race they
// close is not deterministic here, so their absence is invisible until it is
// not. Removing the anchor ENTIRELY does red six cells, which is what shows
// the construct is load-bearing rather than decorative.
//
// The queryable families need no anchor: a get is a complete round trip and
// its reply set is closed when `toList()` completes.
//
// ONE THING THE QUERYABLE PATTERNS HAD TO CHANGE, and why it is a fix rather
// than a weakening: they query with `ConsolidationMode.none`. The originals
// have exactly one queryable per key and read `replies.any((r) => r.isOk)`;
// these have two (the restricted one and its witness), both replying on the
// same key expression, and canon's default consolidation collapses same-key
// replies to one. Measured on the first probe run: the restricted reply and
// the witness reply erased each other, so a mode read `{witness}` where the
// truth was `{witness, restricted}`. With consolidation off, both survive and
// the reading is by PAYLOAD, not by "did anything answer".
//
// THE NEGATIVE CONTROL, AND WHY ITS ZERO IS WORTH READING
//
// "A sample that crossed the router is classified remote" needs a companion
// that could have caught a green produced by something other than the route.
// The split control is a `Locality.remote` subscriber -- the mode that ADMITS
// router-carried traffic, so the most permissive possible reader of the claim
// -- observing a publisher leaf with identical flags that dials a SECOND,
// unlinked router. Its zero is only worth reading because the OBSERVING
// side's readiness is asserted first: a probe leaf's publisher on the
// subscriber's own router reports a match, so the subscriber demonstrably
// declared and demonstrably crossed a router. It just did not cross THAT one.
//
// PORTS: 19875-19879, this file's block of the unit's 19800-19899 band.
// 19875 carries all five declaration families; 19876 carries the split
// control's linked router and 19877 the unlinked one it never reaches.
// 19878 and 19879 are unallocated.

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/routed_topology.dart';

/// The router all five declaration families cross.
const _routerPort = 19875;

/// The split control's linked router -- the one its subscriber attaches to.
const _splitLinkedPort = 19876;

/// The split control's unlinked router. Nothing ever crosses between this
/// one and [_splitLinkedPort]; that is the whole point of it.
const _splitStrayPort = 19877;

/// How long the two "never advertised" cells and the split control wait
/// before concluding that nothing was observed.
///
/// It must exceed the positive path's convergence by a clear margin or a slow
/// green reads as a red. Measured on this host, a publisher reports a
/// matching routed subscriber within 50 ms of declaring; five seconds is the
/// interval this unit's other absence cells already use.
const _negativeWindow = Duration(seconds: 5);

/// The bound on every get this file issues.
///
/// A ceiling, not a delay: a get completes as soon as its matched queryables
/// have finalized. It is stated so that a query nobody answers fails inside
/// the cell's own timeout rather than at the file's.
const _getTimeout = Duration(seconds: 3);

/// The payload published by the REMOTE source, which must cross the router.
const _fromRemote = 'from-remote';

/// The payload published by leaf B into its own session.
const _fromLocal = 'from-local';

/// The remote source's terminal marker. See the header: it is what makes an
/// absence readable without a sleep.
const _remoteMarker = 'remote-marker';

/// The local source's terminal marker.
const _localMarker = 'local-marker';

/// The reply payload of the entity under test.
const _restrictedReply = 'restricted';

/// The reply payload of its unrestricted witness.
const _witnessReply = 'witness';

/// What a pattern reports: which of the two sources the restricted entity
/// admitted. The same record shape the originals return, so a counterpart
/// and its original read alike.
typedef _Outcome = ({bool fromRemote, bool fromLocal});

/// Collects payloads from [stream] for the rest of the test.
List<String> _payloadsOf(Stream<Sample> stream) {
  final seen = <String>[];
  final subscription = stream.listen((sample) => seen.add(sample.payload));
  addTearDown(subscription.cancel);
  return seen;
}

/// Publishes from both sources on [key] and returns only once every one of
/// them has provably been dispatched to the declaring session.
///
/// The readiness is exact rather than a settle: a publisher on [remoteLeaf]
/// reporting a match IS the router having propagated the declaration back to
/// it, so the remote put cannot be emitted into a void. The two markers are
/// the anchor described in this file's header, and [witnessed] is the
/// unrestricted twin's payload list -- the thing that observes them.
Future<void> _driveBothSources({
  required Session remoteLeaf,
  required Session localLeaf,
  required String key,
  required List<String> witnessed,
}) async {
  final publisher = remoteLeaf.declarePublisher(key);
  addTearDown(publisher.close);
  await awaitMatching(publisher.hasMatchingSubscribers);

  publisher.put(_fromRemote);
  localLeaf.put(key, _fromLocal);
  publisher.put(_remoteMarker);
  localLeaf.put(key, _localMarker);

  await awaitCondition(
    () => const [
      _fromRemote,
      _fromLocal,
      _remoteMarker,
      _localMarker,
    ].every(witnessed.contains),
    description:
        'the unrestricted witness on "$key" to receive both sources '
        'and both markers',
  );
}

/// Queries [key] from [from] and returns the payloads of its OK replies.
///
/// `ConsolidationMode.none` because two queryables answer on the same key
/// here and canon's default collapses them to one. See the header.
Future<Set<String>> _ask(Session from, String key) async {
  final replies = await from
      .get(key, timeout: _getTimeout, consolidation: ConsolidationMode.none)
      .toList();
  return replies.where((r) => r.isOk).map((r) => r.ok.payload).toSet();
}

/// Declares a queryable that answers [reply], and disposes each query.
void _answerWith(Stream<Query> queries, String key, String reply) {
  final subscription = queries.listen((query) {
    query
      ..reply(key, reply)
      ..dispose();
  });
  addTearDown(subscription.cancel);
}

void main() {
  // ⛔⛔ THE SCOPE OF THIS FILE'S FINDING, stated because it is exactly the
  // kind of claim that widens on its way downstream.
  //
  // Measured here: allowedOrigin classification survives the router hop
  // UNCHANGED on all five declaration families. ⛔ THAT IS MEASURED FOR ONE
  // ROUTER KIND -- an in-process `mode:"router"` session, which is what
  // HostedRouter opens. It is NOT measured through the pinned `zenohd`
  // daemon, and this unit has already established that THE ROUTER KIND CAN
  // CHANGE THE ANSWER: a shared-memory payload arrives [SHM (MUT)] through an
  // in-process router and through a canon C binary run `-m router`, and [RAW]
  // through the daemon, on the same host under the same ceiling.
  //
  // ▶ So the honest statement is "locality survives an IN-PROCESS routed hop",
  // and "locality survives routing" is a wider claim nobody has tested. The
  // daemon arm belongs to the interop tier, where a daemon is already a hard
  // requirement.
  group('allowedOrigin over one hosted router (TCP 19875)', () {
    late HostedRouter router;

    /// The REMOTE source. Client mode, which is what makes the pair routed
    /// rather than isolated.
    late Session leafA;

    /// The declaring session. Everything under test lives here, and its own
    /// puts are the same-session source.
    late Session leafB;

    setUpAll(() async {
      router = await HostedRouter.open(_routerPort);
      leafA = await Session.open(config: router.leafConfig(LeafMode.client));
      leafB = await Session.open(config: router.leafConfig(LeafMode.peer));

      // Readiness is each leaf's own view of its router, never a sleep, plus
      // the router's independent view of the peer leaf.
      await router.awaitAttached(leafA);
      await router.awaitAttached(leafB);
      await router.awaitPeerLeaf(leafB.zid);
    });

    tearDownAll(() {
      leafB.close();
      leafA.close();
      router.close();
    });

    test('each leaf reports exactly the router it was pointed at', () {
      // The precondition every other cell in this group rests on, asserted
      // once. Without it a discrimination reading would be satisfied by two
      // leaves that connected to nothing and never exchanged anything.
      expect(leafA.routersZid(), hasLength(1));
      expect(leafA.routersZid().single, equals(router.zid));
      expect(leafB.routersZid(), hasLength(1));
      expect(leafB.routersZid().single, equals(router.zid));
      expect(router.peersZid(), contains(leafB.zid));
    });

    test(
      'a sessionLocal subscriber is never advertised through the router',
      () async {
        // The measured ground for the witness. It is stated as a cell rather
        // than a comment because the whole readiness design of this file rests
        // on it: a gate keyed on the entity under test would HANG for one of
        // the three modes every cell has to cover.
        //
        // CONTROL FIRST. A `remote`-origin subscriber on the same leaf, the
        // same router and the same publisher shape IS advertised, so the zero
        // below is the origin setting and not a dead route.
        const controlKey = 'zenoh/dart/test/routed/locality/advertised/remote';
        final control = leafB.declareSubscriber(
          controlKey,
          allowedOrigin: Locality.remote,
        );
        addTearDown(control.close);
        final controlPublisher = leafA.declarePublisher(controlKey);
        addTearDown(controlPublisher.close);
        await awaitMatching(controlPublisher.hasMatchingSubscribers);

        const localKey = 'zenoh/dart/test/routed/locality/advertised/local';
        final local = leafB.declareSubscriber(
          localKey,
          allowedOrigin: Locality.sessionLocal,
        );
        addTearDown(local.close);
        final localPublisher = leafA.declarePublisher(localKey);
        addTearDown(localPublisher.close);

        await Future<void>.delayed(_negativeWindow);

        expect(
          localPublisher.hasMatchingSubscribers(),
          isFalse,
          reason:
              'canon does not advertise a sessionLocal declaration beyond '
              'its own session, so a remote publisher never sees it -- which '
              'is why every pattern in this file gates on an unrestricted '
              'witness instead of on the entity under test',
        );
      },
    );

    test(
      'a sessionLocal queryable is never reachable through the router',
      () async {
        // The get/reply half of the cell above, and it needs no window at all:
        // an unanswered get is bounded by its own timeout.
        const controlKey = 'zenoh/dart/test/routed/locality/reachable/remote';
        final control = leafB.declareQueryable(
          controlKey,
          allowedOrigin: Locality.remote,
        );
        addTearDown(control.close);
        _answerWith(control.stream, controlKey, _restrictedReply);
        await awaitRoutedQueryable(router, controlKey);

        expect(
          await _ask(leafA, controlKey),
          contains(_restrictedReply),
          reason:
              'CONTROL: a remote-origin queryable IS reachable through the '
              'router, so the absence below is the origin setting',
        );

        const localKey = 'zenoh/dart/test/routed/locality/reachable/local';
        final local = leafB.declareQueryable(
          localKey,
          allowedOrigin: Locality.sessionLocal,
        );
        addTearDown(local.close);
        _answerWith(local.stream, localKey, _restrictedReply);

        expect(
          await _ask(leafA, localKey),
          isEmpty,
          reason:
              'a sessionLocal queryable answers nothing that arrived '
              'through the router',
        );
        expect(
          await _ask(leafB, localKey),
          contains(_restrictedReply),
          reason:
              'LIVENESS: the same queryable answers its own session, so '
              'the zero above is the filter and not a dead declaration',
        );
      },
    );

    test('the routed shape does not reclassify a same-session put', () async {
      // The claim the slice asks for in its own cell: a router in the path
      // must not make a session's own publication look remote to it, and
      // must not make a router-carried one look local. Both readings are
      // taken from the SAME put pair, on one key, so neither can be an
      // artifact of a different moment.
      const key = 'zenoh/dart/test/routed/locality/reclassify';

      final localOnly = leafB.declareSubscriber(
        key,
        allowedOrigin: Locality.sessionLocal,
      );
      addTearDown(localOnly.close);
      final localSeen = _payloadsOf(localOnly.stream);

      final remoteOnly = leafB.declareSubscriber(
        key,
        allowedOrigin: Locality.remote,
      );
      addTearDown(remoteOnly.close);
      final remoteSeen = _payloadsOf(remoteOnly.stream);

      final witness = leafB.declareSubscriber(key);
      addTearDown(witness.close);
      final witnessed = _payloadsOf(witness.stream);

      await _driveBothSources(
        remoteLeaf: leafA,
        localLeaf: leafB,
        key: key,
        witnessed: witnessed,
      );

      expect(
        localSeen,
        contains(_fromLocal),
        reason:
            'a genuinely same-session put is still local with a router '
            'in the path',
      );
      expect(localSeen, isNot(contains(_fromRemote)));
      expect(
        remoteSeen,
        contains(_fromRemote),
        reason: 'a put that crossed the router is classified remote',
      );
      expect(remoteSeen, isNot(contains(_fromLocal)));
    });

    group('declareSubscriber allowedOrigin, routed', () {
      Future<_Outcome> pattern(
        String ke,
        Locality? origin, {
        bool omit = false,
      }) async {
        final subscriber = omit
            ? leafB.declareSubscriber(ke)
            : leafB.declareSubscriber(ke, allowedOrigin: origin);
        addTearDown(subscriber.close);
        final restricted = _payloadsOf(subscriber.stream);

        final witness = leafB.declareSubscriber(ke);
        addTearDown(witness.close);
        final witnessed = _payloadsOf(witness.stream);

        await _driveBothSources(
          remoteLeaf: leafA,
          localLeaf: leafB,
          key: ke,
          witnessed: witnessed,
        );

        return (
          fromRemote: restricted.contains(_fromRemote),
          fromLocal: restricted.contains(_fromLocal),
        );
      }

      test('declareSubscriber discriminates in all three modes', () async {
        expect(
          await pattern('zenoh/dart/test/d/sub/any', Locality.any),
          (fromRemote: true, fromLocal: true),
          reason:
              'CONTROL: both sources must reach an unrestricted routed '
              'subscriber, or the restricted legs below prove nothing',
        );
        expect(
          await pattern('zenoh/dart/test/d/sub/remote', Locality.remote),
          (fromRemote: true, fromLocal: false),
        );
        expect(
          await pattern('zenoh/dart/test/d/sub/local', Locality.sessionLocal),
          (fromRemote: false, fromLocal: true),
        );
      });

      test('declareSubscriber omitting allowedOrigin is canon ANY', () async {
        expect(
          await pattern('zenoh/dart/test/d/sub/omitted', null, omit: true),
          (fromRemote: true, fromLocal: true),
        );
      });
    });

    group('declareBackgroundSubscriber allowedOrigin, routed', () {
      Future<_Outcome> pattern(
        String ke,
        Locality? origin, {
        bool omit = false,
      }) async {
        final stream = omit
            ? leafB.declareBackgroundSubscriber(ke)
            : leafB.declareBackgroundSubscriber(ke, allowedOrigin: origin);
        final restricted = _payloadsOf(stream);

        final witness = leafB.declareSubscriber(ke);
        addTearDown(witness.close);
        final witnessed = _payloadsOf(witness.stream);

        await _driveBothSources(
          remoteLeaf: leafA,
          localLeaf: leafB,
          key: ke,
          witnessed: witnessed,
        );

        return (
          fromRemote: restricted.contains(_fromRemote),
          fromLocal: restricted.contains(_fromLocal),
        );
      }

      test(
        'declareBackgroundSubscriber discriminates in all three modes',
        () async {
          expect(
            await pattern('zenoh/dart/test/d/bgsub/any', Locality.any),
            (fromRemote: true, fromLocal: true),
            reason:
                'CONTROL: both sources must reach an unrestricted routed '
                'background subscriber',
          );
          expect(
            await pattern('zenoh/dart/test/d/bgsub/remote', Locality.remote),
            (fromRemote: true, fromLocal: false),
          );
          expect(
            await pattern(
              'zenoh/dart/test/d/bgsub/local',
              Locality.sessionLocal,
            ),
            (fromRemote: false, fromLocal: true),
          );
        },
      );

      test(
        'declareBackgroundSubscriber omitting allowedOrigin is canon ANY',
        () async {
          expect(
            await pattern('zenoh/dart/test/d/bgsub/omitted', null, omit: true),
            (fromRemote: true, fromLocal: true),
          );
        },
      );
    });

    group('declarePullSubscriber allowedOrigin, routed', () {
      Future<_Outcome> pattern(
        String ke,
        Locality? origin, {
        bool omit = false,
      }) async {
        final pull = omit
            ? leafB.declarePullSubscriber(ke)
            : leafB.declarePullSubscriber(ke, allowedOrigin: origin);
        addTearDown(pull.close);

        // The witness is a STREAM subscriber, deliberately not a second pull
        // channel: readiness taken from the same carrier the cell then reads
        // would be part of the observation rather than a precondition for
        // it. Nothing here ever takes from the channel under test except the
        // drain below.
        final witness = leafB.declareSubscriber(ke);
        addTearDown(witness.close);
        final witnessed = _payloadsOf(witness.stream);

        await _driveBothSources(
          remoteLeaf: leafA,
          localLeaf: leafB,
          key: ke,
          witnessed: witnessed,
        );

        // Poll to exhaustion rather than assuming an arrival order, as the
        // original does.
        final restricted = <String>{};
        while (true) {
          if (pull.tryRecv() case RecvData(:final value)) {
            restricted.add(value.payload);
          } else {
            break;
          }
        }
        return (
          fromRemote: restricted.contains(_fromRemote),
          fromLocal: restricted.contains(_fromLocal),
        );
      }

      test('declarePullSubscriber discriminates in all three modes', () async {
        expect(
          await pattern('zenoh/dart/test/d/pull/any', Locality.any),
          (fromRemote: true, fromLocal: true),
          reason: 'CONTROL: both sources must be buffered when unrestricted',
        );
        expect(
          await pattern('zenoh/dart/test/d/pull/remote', Locality.remote),
          (fromRemote: true, fromLocal: false),
        );
        expect(
          await pattern('zenoh/dart/test/d/pull/local', Locality.sessionLocal),
          (fromRemote: false, fromLocal: true),
        );
      });

      test(
        'declarePullSubscriber omitting allowedOrigin is canon ANY',
        () async {
          expect(
            await pattern('zenoh/dart/test/d/pull/omitted', null, omit: true),
            (fromRemote: true, fromLocal: true),
          );
        },
      );
    });

    group('declareQueryable allowedOrigin, routed', () {
      Future<_Outcome> pattern(
        String ke,
        Locality? origin, {
        bool omit = false,
      }) async {
        final queryable = omit
            ? leafB.declareQueryable(ke)
            : leafB.declareQueryable(ke, allowedOrigin: origin);
        addTearDown(queryable.close);
        _answerWith(queryable.stream, ke, _restrictedReply);

        final witness = leafB.declareQueryable(ke);
        addTearDown(witness.close);
        _answerWith(witness.stream, ke, _witnessReply);

        // Exact readiness: a probe leaf's get is ANSWERED through the router,
        // which no transport-level gate can establish. The probe's queries
        // reach both queryables and are replied to; it takes nothing the cell
        // then reads, because the cell's carrier is its own get below.
        await awaitRoutedQueryable(router, ke);

        final remote = await _ask(leafA, ke);
        final local = await _ask(leafB, ke);

        expect(
          remote,
          contains(_witnessReply),
          reason:
              'CONTROL: the unrestricted witness answers the remote get, '
              'so a missing restricted reply is the origin filter',
        );
        expect(
          local,
          contains(_witnessReply),
          reason: 'CONTROL: the unrestricted witness answers the local get',
        );

        return (
          fromRemote: remote.contains(_restrictedReply),
          fromLocal: local.contains(_restrictedReply),
        );
      }

      test('declareQueryable discriminates in all three modes', () async {
        expect(
          await pattern('zenoh/dart/test/d/qbl/any', Locality.any),
          (fromRemote: true, fromLocal: true),
          reason:
              'CONTROL: both getters must be answered when unrestricted, '
              'so an unanswered get below is the locality filter and not a '
              'dead route',
        );
        expect(
          await pattern('zenoh/dart/test/d/qbl/remote', Locality.remote),
          (fromRemote: true, fromLocal: false),
        );
        expect(
          await pattern('zenoh/dart/test/d/qbl/local', Locality.sessionLocal),
          (fromRemote: false, fromLocal: true),
        );
      });

      test('declareQueryable omitting allowedOrigin is canon ANY', () async {
        expect(
          await pattern('zenoh/dart/test/d/qbl/omitted', null, omit: true),
          (fromRemote: true, fromLocal: true),
        );
      });
    });

    group('declareBackgroundQueryable allowedOrigin, routed', () {
      Future<_Outcome> pattern(
        String ke,
        Locality? origin, {
        bool omit = false,
      }) async {
        final stream = omit
            ? leafB.declareBackgroundQueryable(ke)
            : leafB.declareBackgroundQueryable(ke, allowedOrigin: origin);
        _answerWith(stream, ke, _restrictedReply);

        final witness = leafB.declareQueryable(ke);
        addTearDown(witness.close);
        _answerWith(witness.stream, ke, _witnessReply);

        await awaitRoutedQueryable(router, ke);

        final remote = await _ask(leafA, ke);
        final local = await _ask(leafB, ke);

        expect(
          remote,
          contains(_witnessReply),
          reason: 'CONTROL: the unrestricted witness answers the remote get',
        );
        expect(
          local,
          contains(_witnessReply),
          reason: 'CONTROL: the unrestricted witness answers the local get',
        );

        return (
          fromRemote: remote.contains(_restrictedReply),
          fromLocal: local.contains(_restrictedReply),
        );
      }

      test(
        'declareBackgroundQueryable discriminates in all three modes',
        () async {
          expect(
            await pattern('zenoh/dart/test/d/bgqbl/any', Locality.any),
            (fromRemote: true, fromLocal: true),
            reason: 'CONTROL: both getters must be answered when unrestricted',
          );
          expect(
            await pattern('zenoh/dart/test/d/bgqbl/remote', Locality.remote),
            (fromRemote: true, fromLocal: false),
          );
          expect(
            await pattern(
              'zenoh/dart/test/d/bgqbl/local',
              Locality.sessionLocal,
            ),
            (fromRemote: false, fromLocal: true),
          );
        },
      );

      test(
        'declareBackgroundQueryable omitting allowedOrigin is canon ANY',
        () async {
          expect(
            await pattern('zenoh/dart/test/d/bgqbl/omitted', null, omit: true),
            (fromRemote: true, fromLocal: true),
          );
        },
      );

      test(
        'a query delivered through the router is still fully replyable',
        () async {
          // Counterpart of locality_declaration_test.dart:401. The restriction
          // filters WHICH queries arrive, not what can be done with the ones
          // that do -- and a router in the path does not change that.
          const ke = 'zenoh/dart/test/d/bgqbl/replyable';
          final stream = leafB.declareBackgroundQueryable(
            ke,
            allowedOrigin: Locality.remote,
          );
          var disposedCleanly = false;
          final subscription = stream.listen((query) {
            query
              ..reply(ke, 'payload-through')
              ..dispose();
            disposedCleanly = true;
          });
          addTearDown(subscription.cancel);

          await awaitRoutedQueryable(router, ke);

          final replies = await leafA.get(ke, timeout: _getTimeout).toList();
          final ok = replies.where((r) => r.isOk).toList();
          expect(ok, isNotEmpty);
          expect(ok.first.ok.payload, 'payload-through');
          expect(disposedCleanly, isTrue);
        },
      );
    });
  });

  group('An unlinked router carries nothing (TCP 19876, split 19877)', () {
    late HostedRouter linkedRouter;
    late HostedRouter strayRouter;
    late Session subscriberLeaf;
    late Session publisherLeaf;
    late Session strayPublisherLeaf;

    setUpAll(() async {
      linkedRouter = await HostedRouter.open(_splitLinkedPort);
      strayRouter = await HostedRouter.open(_splitStrayPort);

      subscriberLeaf = await Session.open(
        config: linkedRouter.leafConfig(LeafMode.peer),
      );
      publisherLeaf = await Session.open(
        config: linkedRouter.leafConfig(LeafMode.client),
      );
      // Identical flags and identical role to publisherLeaf. The ONLY
      // difference is which router it dials, which is what makes the zero
      // below attributable to the path rather than to the leaf.
      strayPublisherLeaf = await Session.open(
        config: strayRouter.leafConfig(LeafMode.client),
      );

      await linkedRouter.awaitAttached(subscriberLeaf);
      await linkedRouter.awaitAttached(publisherLeaf);
      await strayRouter.awaitAttached(strayPublisherLeaf);
    });

    tearDownAll(() {
      strayPublisherLeaf.close();
      publisherLeaf.close();
      subscriberLeaf.close();
      strayRouter.close();
      linkedRouter.close();
    });

    test('each leaf reports exactly the router it was pointed at', () {
      expect(subscriberLeaf.routersZid(), hasLength(1));
      expect(subscriberLeaf.routersZid().single, equals(linkedRouter.zid));
      expect(publisherLeaf.routersZid(), hasLength(1));
      expect(publisherLeaf.routersZid().single, equals(linkedRouter.zid));

      expect(strayPublisherLeaf.routersZid(), hasLength(1));
      expect(strayPublisherLeaf.routersZid().single, equals(strayRouter.zid));
      expect(strayRouter.zid, isNot(equals(linkedRouter.zid)));
    });

    test(
      'a remote-origin subscriber admits nothing from another router',
      () async {
        // `Locality.remote` is the most permissive possible reader of this
        // file's central claim -- it is the mode that ADMITS router-carried
        // traffic -- so a zero here cannot be the origin filter. It is the
        // path.
        const key = 'zenoh/dart/test/routed/locality/split';
        const stray = 'from-the-other-router';
        const carried = 'from-this-router';

        final subscriber = subscriberLeaf.declareSubscriber(
          key,
          allowedOrigin: Locality.remote,
        );
        addTearDown(subscriber.close);
        final seen = _payloadsOf(subscriber.stream);

        // THE OBSERVING SIDE'S READINESS, asserted before the zero is read: a
        // probe leaf's publisher on the subscriber's OWN router reports a
        // match, so the subscriber demonstrably declared and demonstrably
        // crossed a router.
        await awaitRoutedSubscriber(linkedRouter, key);

        final strayPublisher = strayPublisherLeaf.declarePublisher(key);
        addTearDown(strayPublisher.close);
        strayPublisher.put(stray);

        await Future<void>.delayed(_negativeWindow);

        expect(seen, isEmpty);
        // A second, independent reading of the same absence.
        expect(strayPublisher.hasMatchingSubscribers(), isFalse);

        // LIVENESS: the same subscriber, the same mode, the same key -- fed
        // from a leaf on the router it IS attached to. Without this the zero
        // above is satisfied by a subscriber that never worked.
        final publisher = publisherLeaf.declarePublisher(key);
        addTearDown(publisher.close);
        await awaitMatching(publisher.hasMatchingSubscribers);
        publisher.put(carried);
        await awaitCondition(
          () => seen.contains(carried),
          description: "the routed subscriber to receive its own router's put",
        );
        expect(seen, isNot(contains(stray)));
      },
    );
  });
}
