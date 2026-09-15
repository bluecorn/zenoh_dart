// Seed [OWN] — the driver every finalizer cell runs behind.
//
// WHY A SUBPROCESS PER CELL. Two reasons, both hard.
//
// 1. `zd_fin_invocations()` is a PROCESS-WIDE counter that is never reset. Two
//    cells sharing a process would read each other's firings, and the second
//    one to run could not tell its own release from its neighbour's. A fresh
//    process is what makes "this arm produced exactly N firings" a statement
//    about this arm.
// 2. `MALLOC_PERTURB_` — the named driver for the premature-free class — is
//    read by glibc ONCE at startup. It cannot be set for part of a process.
//
// WHY A COUNTER AT ALL, RATHER THAN A BEHAVIOURAL ASSERTION. A leak is
// invisible to behaviour: dispose-after-consume, double-dispose,
// mark-idempotence and accessor-guard cells all pass IDENTICALLY on leaking and
// on fixed code — nine such cells were once written for a real leak and all
// nine passed on both legs. A release-path cell has to measure the RESOURCE.
//
// ⛔ AND EVERY ARM CARRIES A BOTH-WAYS CALIBRATION, because the failure mode we
// actually hit is an instrument that cannot see the thing:
//   no-attach              the false-GREEN direction. A cell that would pass
//                          with no finalizer attached is worthless, and this
//                          arm is what shows it would not: the counter must
//                          stay 0 through the full round cap.
//   attach-without-detach  the fault direction. The counter must resolve one
//                          firing from two, or a missed detach reads the same
//                          as a correct one.
//
// GC FORCING. Allocation pressure — 32 x `List<int>.filled(1 << 18, i)` per
// round, with an event-loop turn between rounds so the collector can actually
// run — capped at 120 rounds. Nothing here waits on a finalizer without a
// bound: an unbounded wait-for-condition converts a defect into a frozen
// serial suite, which is the most expensive failure available.
//
// THE THREAD IS PRINTED BESIDE EVERY OBSERVATION, and that is not decoration.
// A hypothesis of the form "the callback runs on the finalizer thread and
// freezes the isolate group" cannot be established by a stopwatch: a blocking
// release reached from the MUTATOR blocks that mutator inside GC instead — a
// different failure with an identical observable. `FIN_ON_MAIN` is what
// separates them.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/keyexpr.dart' show withLoanedKeyExpr;
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

/// The round cap. A finalizer that has not fired in this many rounds of
/// pressure is reported as not having fired, with the cap stated — never
/// waited on indefinitely.
const int kRoundCap = 120;

/// One round of allocation pressure.
///
/// The shape measured to fire a finalizer on round 1 in 4 of 4 runs. The
/// `await` is load-bearing: the collector needs an event-loop turn, and a tight
/// synchronous loop starves it.
Future<void> _pressureRound(int i) async {
  final ballast = <List<int>>[];
  for (var j = 0; j < 32; j++) {
    ballast.add(List<int>.filled(1 << 18, i + j));
  }
  // Touch it so the allocation cannot be elided.
  if (ballast.last.last == -1) stdout.writeln('UNREACHABLE');
  await Future<void>.delayed(Duration.zero);
}

/// Applies pressure until [kind]'s counter reaches [target], or the cap.
///
/// Returns the round at which it reached the target, or -1.
Future<int> _pressureUntil(int kind, int target) async {
  for (var round = 1; round <= kRoundCap; round++) {
    await _pressureRound(round);
    if (bindings.zd_fin_invocations(kind) >= target) return round;
  }
  return -1;
}

/// Runs the full cap regardless — the shape a zero-expecting arm needs.
Future<void> _pressureFully() async {
  for (var round = 1; round <= kRoundCap; round++) {
    await _pressureRound(round);
  }
}

void _report(int kind, {required int round}) {
  stdout
    ..writeln('FIN_ROUND=$round')
    ..writeln('FIN_COUNT kind=$kind value=${bindings.zd_fin_invocations(kind)}')
    ..writeln(
      'FIN_ON_MAIN kind=$kind value=${bindings.zd_fin_last_on_main(kind)}',
    );
}

// ---------------------------------------------------------------------------
// A holder used ONLY by the two calibration arms.
// ---------------------------------------------------------------------------

/// A minimal `Finalizable` with its own native block.
///
/// Deliberately NOT a shipped wrapper: the calibration arms exist to
/// characterise the INSTRUMENT, and doing that through a shipped class would
/// require a test-only backdoor into it.
class _Holder implements Finalizable {
  _Holder();
  final Pointer<Uint8> block = calloc<Uint8>(64);
  final Pointer<Uint8> second = calloc<Uint8>(64);
}

@pragma('vm:never-inline')
void _makeHolderAttachedTwice() {
  final h = _Holder();
  // TWO attachments, TWO distinct blocks, NO detach key on either. Dropping
  // this holder fires the entry twice.
  //
  // ⚠️ WHAT THIS DOES AND DOES NOT MODEL, stated because the plan's wording
  // for this arm is "dispose() is called AND the finalizer is left attached".
  // Modelling that literally means freeing ONE block TWICE, which is a genuine
  // double free: undefined behaviour, and under `MALLOC_PERTURB_` an abort —
  // so the arm would characterise the allocator, not the counter. The question
  // this arm has to answer is narrower and is fully answered here: CAN THIS
  // COUNTER RESOLVE ONE FIRING FROM TWO? If it cannot, a missed detach reads
  // exactly like a correct release and every other arm in this file is
  // worthless. Two attachments answer that without corrupting the heap.
  freeBlockFinalizer
    ..attach(h, h.block.cast())
    ..attach(h, h.second.cast());
}

@pragma('vm:never-inline')
void _makeHolderNeverAttached() {
  final h = _Holder();
  // Never attached. The blocks leak on purpose: this arm's whole assertion is
  // that the counter does NOT move, and a released block would be the one
  // thing that could move it.
  if (h.block.address == 0) stdout.writeln('UNREACHABLE');
}

// ---------------------------------------------------------------------------
// Config arms
// ---------------------------------------------------------------------------
//
// ⚠️ THE PER-CLASS CALIBRATION IS THE SHIPPED-PATH PAIR, not a synthetic
// fault injection, and the reason is worth stating once here for every class
// slice that follows.
//
// The literal fault -- "dispose() ran AND the finalizer is still attached" --
// means `zd_config_drop` and `free()` running twice on ONE block. The drop is
// a documented safe no-op on a gravestoned handle, but the second `free()` is
// a genuine double free: glibc aborts, and under `MALLOC_PERTURB_` it aborts
// harder. An arm that "proves" the detach matters by crashing the process is
// not an assertion (the no-fake-red-leg rule), and a crashed child cannot
// report a counter.
//
// So the per-class both-ways separation is driven through the SHIPPED code
// paths on the SAME counter kind: drop-without-release reads 1, and every
// explicit release path reads 0. That the counter can resolve 1 from 2 at all
// -- which is what makes a missed detach visible rather than
// indistinguishable -- is established once, at instrument level, by the
// `attach-without-detach` arm above.

Config _quietConfig() => Config()
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('scouting/gossip/enabled', 'false');

@pragma('vm:never-inline')
void _makeConfigAndDrop() {
  final c = _quietConfig();
  if (c.hashCode == -1) stdout.writeln('UNREACHABLE');
}

@pragma('vm:never-inline')
void _makeConfigAndDispose() {
  _quietConfig().dispose();
}

@pragma('vm:never-inline')
Future<void> _openSessionWithExplicitConfig() async {
  // `Session.open` CONSUMES the config and marks it. markConsumed() FREES the
  // Dart block, so a missed detach here is a double free rather than a leak.
  (await Session.open(config: _quietConfig())).close();
}

@pragma('vm:never-inline')
Future<void> _openSessionWithInternalConfig() async {
  // The config `Session.open` builds for itself has no other owner; its
  // reclamation depends entirely on the same markConsumed path.
  (await Session.open()).close();
}

// ---------------------------------------------------------------------------
// ZBytes arms
// ---------------------------------------------------------------------------

@pragma('vm:never-inline')
void _makeBytesAndDrop() {
  final b = ZBytes.fromString('own-slice5');
  if (b.hashCode == -1) stdout.writeln('UNREACHABLE');
}

@pragma('vm:never-inline')
void _makeBytesAndDispose() {
  ZBytes.fromString('own-slice5').dispose();
}

@pragma('vm:never-inline')
void _publishAndDrop(Session s, int n) {
  // The CLONE-IN-LOOP shape: a payload built and handed to the send path per
  // message, its reference dropped immediately. `putBytes` consumes and marks,
  // and markConsumed FREES the block -- so a missed detach here is one double
  // free per message, not a leak.
  for (var i = 0; i < n; i++) {
    s.putBytes('demo/own/fin/b', ZBytes.fromString('m$i'));
  }
}

// ---------------------------------------------------------------------------
// KeyExpr arms
// ---------------------------------------------------------------------------

@pragma('vm:never-inline')
void _makeViewKeyExprAndDrop() {
  // A VIEW backing: a `calloc`'d view slot AND a `malloc`'d string, so TWO
  // attachments and therefore TWO firings.
  final k = KeyExpr('demo/own/fin/view');
  if (k.value.isEmpty) stdout.writeln('UNREACHABLE');
}

@pragma('vm:never-inline')
void _makeViewKeyExprAndDispose() {
  KeyExpr('demo/own/fin/view').dispose();
}

@pragma('vm:never-inline')
void _makeOwnedKeyExprAndDrop(Session s) {
  // An OWNED backing: one block, one canon handle, ONE attachment on the
  // keyexpr entry -- and the free-block counter must stay at 0.
  final k = s.declareKeyExpr('demo/own/fin/owned');
  if (k.value.isEmpty) stdout.writeln('UNREACHABLE');
}

// ---------------------------------------------------------------------------
// ZBytesWriter / ZSerializer arms
// ---------------------------------------------------------------------------
//
// Both carry a THIRD state the `_consumed` vocabulary does not name:
// `_finished`. `finish()` moves the handle into canon and frees the slot, so
// it is a RELEASE path and must detach exactly as `markConsumed()` does.

@pragma('vm:never-inline')
void _makeWriterAndDrop() {
  final w = ZBytesWriter()..writeAll(Uint8List.fromList(<int>[1, 2, 3]));
  if (w.hashCode == -1) stdout.writeln('UNREACHABLE');
}

@pragma('vm:never-inline')
void _makeWriterAndFinish() {
  final w = ZBytesWriter()..writeAll(Uint8List.fromList(<int>[1, 2, 3]));
  w.finish().dispose();
}

@pragma('vm:never-inline')
void _makeWriterFinishThenDispose() {
  final w = ZBytesWriter()..writeAll(Uint8List.fromList(<int>[4, 5]));
  w.finish().dispose();
  // A second release call on an already-finished writer: the "safe to call
  // multiple times" contract must survive the detach, and must not
  // double-detach into anything.
  w.dispose();
}

@pragma('vm:never-inline')
void _makeSerializerAndDrop() {
  final z = ZSerializer()
    ..serializeUint8(1)
    ..serializeUint8(2);
  if (z.hashCode == -1) stdout.writeln('UNREACHABLE');
}

@pragma('vm:never-inline')
void _makeSerializerAndFinish() {
  final z = ZSerializer()..serializeUint8(9);
  z.finish().dispose();
}

@pragma('vm:never-inline')
void _makeWriterAbandonedOnError() {
  // THE NET'S WHOLE PURPOSE: a LIVE, UN-FINISHED writer that a caller's error
  // handling drops on the floor.
  //
  // ⚠️ The first cut of this arm was WRONG and the counter caught it. It
  // finished the writer and then called `writeAll` on it to provoke the throw
  // -- but `finish()` is itself a correct release, so the writer had already
  // been handed over cleanly and the counter read 0. The arm was measuring a
  // properly-released writer while claiming to measure an abandoned one.
  //
  // The failure has to come from the CALLER, not from the writer's own state
  // machine, or the writer is not abandoned at all.
  try {
    ZBytesWriter().writeAll(Uint8List.fromList(<int>[1, 2, 3]));
    throw const FormatException('caller failed mid-assembly');
  } on FormatException {
    // Abandoned here: never finished, never disposed. Only the net reclaims it.
  }
}

// ---------------------------------------------------------------------------
// Publisher / AdvancedPublisher arms
// ---------------------------------------------------------------------------

@pragma('vm:never-inline')
void _makePublisherAndDrop(Session s, {required bool ml}) {
  final p = s.declarePublisher(
    'demo/own/fin/pub',
    enableMatchingListener: ml,
  );
  if (ml) p.matchingStatus!.listen((_) {});
  if (p.keyExpr.isEmpty) stdout.writeln('UNREACHABLE');
}

@pragma('vm:never-inline')
void _makeAdvancedPublisherAndDrop(Session s, {required bool ml}) {
  final p = s.declareAdvancedPublisher(
    'demo/own/fin/apub',
    options: AdvancedPublisherOptions(enableMatchingListener: ml),
  );
  if (ml) p.matchingStatus!.listen((_) {});
  if (p.keyExpr.isEmpty) stdout.writeln('UNREACHABLE');
}

/// CRITERION (i), driven: is the wrapper collected while something a USER MUST
/// HOLD IN ORDER TO USE IT is still live?
///
/// ⛔ Measured SEPARATELY per class. `Publisher` and `AdvancedPublisher` are
/// different classes with different surfaces, and the family-term lesson
/// forbids inferring either from the other -- inferring `Querier` from
/// `Publisher` on this exact axis is what cost two admission rows.
Future<void> _reachArm(String label, Object Function() make) async {
  // What the ml:off surface hands out, enumerated: `keyExpr` is a Dart String
  // COPY, `hasMatchingSubscribers()` is a bool, `matchingStatus` is NULL, and
  // put/putBytes/deleteResource are synchronous and return void. So there is
  // nothing derived that can outlive the reference -- which is the claim under
  // test, and the assertion below is that the enumeration is complete.
  var ref = WeakReference<Object>(make());
  final kept = <Object>[make()]; // the positive control

  var collectedAt = -1;
  for (var round = 1; round <= kRoundCap; round++) {
    await _pressureRound(round);
    if (ref.target == null) {
      collectedAt = round;
      break;
    }
  }
  stdout
    ..writeln('FIN_REACH_$label=$collectedAt')
    ..writeln('FIN_REACH_CONTROL=${kept.length}');
  // ⛔ THE CONTROL. If the kept-in-a-list object were ALSO collected the
  // instrument would be reporting collection for everything and the row above
  // would mean nothing.
  final controlRef = WeakReference<Object>(kept.first);
  await _pressureRound(kRoundCap + 1);
  stdout.writeln(
    'FIN_REACH_CONTROL_LIVE=${controlRef.target != null ? 1 : 0}',
  );
  ref = WeakReference<Object>(kept.first);
}

// ---------------------------------------------------------------------------
// ShmProvider arms
// ---------------------------------------------------------------------------
//
// ⚠️ THE RESOURCE IS DIRECTLY OBSERVABLE AT **PROVIDER** LEVEL, which is what
// makes this class different from `ShmMutBuffer`. Creating and releasing a
// PROVIDER moves `/dev/shm` entries and open file descriptors; releasing a
// CHUNK moves them by zero. So the SHM instrument named in A3 applies here and
// NOT one slice further on.

int _devShmEntries() {
  try {
    return Directory('/dev/shm').listSync().length;
  } on Object {
    return -1;
  }
}

/// The NAMES in `/dev/shm`, not the count.
///
/// ⛔ WHY A SET AND NOT A COUNT. `/dev/shm` is machine-global. A count delta
/// asks "did the number of segments on this MACHINE go up", which a sibling
/// process answers as easily as we do — under `--concurrency=4` a sibling
/// released two segments inside the measurement window and the delta came back
/// `-2` for a provider that was demonstrably still holding one. The set
/// difference asks the question actually intended: "did an entry appear that
/// was not here before". A sibling's RELEASE cannot remove an entry we added,
/// so the failure mode that produced the red cannot recur.
Set<String> _devShmNames() {
  try {
    return Directory('/dev/shm')
        .listSync()
        .map((e) => e.path.split('/').last)
        .toSet();
  } on Object {
    return const <String>{};
  }
}

int _openFds() {
  try {
    return Directory('/proc/self/fd').listSync().length;
  } on Object {
    return -1;
  }
}

@pragma('vm:never-inline')
void _makeProviderAndDrop() {
  final p = ShmProvider(size: 65536);
  if (p.hashCode == -1) stdout.writeln('UNREACHABLE');
}

// ---------------------------------------------------------------------------
// ShmMutBuffer arms
// ---------------------------------------------------------------------------
//
// ⛔ THE CHUNK-LEVEL INSTRUMENT IS POOL EXHAUSTION THROUGH `allocGc`, and both
// obvious alternatives are measured unfit. `ShmProvider.available` WAS a
// CONSTANT 0 at every lifecycle point -- ⚠️ and it no longer exists: [SHM]
// shared-memory-lifetime REMOVED it on exactly that measurement, which is now
// recorded on the M5 carve ledger rather than in a dartdoc. The measurement
// stands and is why it is not an option here; the member is simply gone.
// And `/dev/shm` entries, fds and mappings move by ZERO on a CHUNK release --
// they discriminate at PROVIDER level only, which is slice 10's cell, not
// this one.
//
// ⚠️ `allocGc`, NEVER plain `alloc`: `alloc` after a release returns
// AllocError because it does not process the deallocation queue, so a cell
// reaching for it goes red on correct code.

const int _shmPool = 65536;
const int _shmChunk = 40960;

@pragma('vm:never-inline')
void _allocAndDrop(ShmProvider p) {
  final r = p.allocGc(_shmChunk);
  if (r is! AllocOk) {
    stdout.writeln('FIN_SHM_CYCLE_ALLOC_FAILED=$r');
    exit(2);
  }
  if (r.buffer.length != _shmChunk) stdout.writeln('UNREACHABLE');
}

@pragma('vm:never-inline')
void _allocAndWriteFiveTimes(ShmProvider p) {
  // ⚠️ The alloc AND the five writes happen in a callee that does not
  // return the buffer. An earlier cut kept `buffer` in the switch-case's own
  // scope, so it was still reachable when the pressure ran and NOTHING fired
  // -- the arm reported 0 and would have read as "nothing was released".
  //
  // ⛔ RETARGETED 2026-09-02 (unit [SHM] shared-memory-lifetime, slice 4).
  // This was `_allocAndReadDataFiveTimes`, and its subject was the ESCAPE
  // TRANSITION: five reads of `ShmMutBuffer.data` had to downgrade the net to
  // slot-only exactly ONCE, because five attachments on one slot would be
  // five frees of it. That transition is not what this drives any more.
  // Every in-tree caller was migrated onto the copying `write` in this slice,
  // and slice 5 removes `data` outright -- at which point the transition
  // cannot be reached at all. Recorded here rather than deleted so the work
  // is traceable: slice 5 is where it went.
  //
  // What it drives now is the same repetition against the copying accessor.
  // `write` must leave the net exactly as it found it, five times over, so
  // the full drop+free entry fires ONCE and the slot-only entry never fires.
  final r = p.alloc(_shmChunk);
  if (r is! AllocOk) {
    stdout.writeln('FIN_SHM_SETUP_FAILED=$r');
    exit(2);
  }
  for (var i = 0; i < 5; i++) {
    r.buffer.write(<int>[i]);
  }
}

/// Reports whether the pool can satisfy another full-size chunk.
int _poolFree(ShmProvider p) {
  final r = p.allocGc(_shmChunk);
  if (r is AllocOk) {
    r.buffer.dispose();
    return 1;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Slice 12 — the kNativePointer measurement
// ---------------------------------------------------------------------------
//
// THE QUESTION, and it is a magnitude rather than a yes/no: how many
// `z_owned_query_t` CLONES are orphaned by the delivered-then-destroyed hole?
//
// `_zd_query_callback` malloc's a clone per query and posts its ADDRESS as a
// bare integer. Dart is what frees it, through `Query.dispose()`. If the VM
// destroys the message before delivering it, that Dart owner never
// materialises and the clone -- block AND canon contents -- is orphaned with
// no reference anywhere. `Dart_CObject_kNativePointer` exists precisely for
// this: its finalizer "will only be invoked if the message is not delivered"
// (the vendored header, verbatim).
//
// ⚠️ NOT to be confused with the FALSE-POST branch, which the shim already
// reclaims at `_zd_query_callback`'s `if (!Dart_PostCObject_DL(...))`. PR #86
// records that branch as "not deterministically drivable at this pin"; it
// stays structural and is not what these arms measure.
//
// The instrument is the shim-side alloc counter filtered to the clone's own
// size class -- `zd_query_sizeof()` -- with `outstanding` at exit being the
// leaked count.
//
// (Corrected: this said the symbol "has no Dart callers", citing the shim's
// own comment. Both were false, and this file is the counter-example: it
// calls `bindings.zd_query_sizeof()` about nine hundred lines below, on the
// KNP arm. The shim-side comment has been corrected too.)

/// Declares a queryable straight onto [port], bypassing `QueryChannel`.
///
/// A bare `ReceivePort` is used deliberately: it gives exact control over
/// WHEN the port closes, which is the whole variable under test, and it does
/// not run `closeAndDrain()` -- that covers the *delivered but unconsumed*
/// case, which is a different row of the table.
Pointer<Void> _declareQueryableOnPort(Session s, String ke, int port) {
  final slot = calloc.allocate<Void>(bindings.zd_queryable_sizeof());
  final rc = withLoanedKeyExpr(ke, 'keyExpr', (loanedKe) {
    return bindings.zd_declare_queryable(
      slot.cast(),
      s.loanedHandle.cast(),
      loanedKe.cast(),
      port,
      0,
      -1,
    );
  });
  if (rc != 0) {
    calloc.free(slot);
    stdout.writeln('KNP_DECLARE_FAILED=$rc');
    exit(2);
  }
  return slot;
}

/// The post-site hook's surface, for the one arm that needs to know whether a
/// finalizer fired at all. Same `.so` slice 3 builds.
class _Hook {
  _Hook(DynamicLibrary lib)
    : install = lib.lookupFunction<Int Function(), int Function()>(
        'zdh_install',
      ),
      uninstall = lib.lookupFunction<Void Function(), void Function()>(
        'zdh_uninstall',
      ),
      reset = lib.lookupFunction<Void Function(), void Function()>('zdh_reset'),
      posts = lib.lookupFunction<Int Function(), int Function()>('zdh_posts'),
      lastOnMain = lib.lookupFunction<Int Function(), int Function()>(
        'zdh_last_on_main_value',
      );

  final int Function() install;
  final void Function() uninstall;
  final void Function() reset;
  final int Function() posts;
  final int Function() lastOnMain;
}

/// Builds the whole falsifier shape and RETURNS NOTHING, so every reference
/// dies here rather than living to the end of the caller.
@pragma('vm:never-inline')
Future<void> _falsifierSetup({required bool withPullChannel}) async {
  final consumer = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19660"]'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final producer = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19660"]'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  final slotAlias = consumer.loanedHandle;
  stdout.writeln('FIN_ALIAS=${slotAlias.address == 0 ? 0 : 1}');

  if (withPullChannel) {
    final pull = consumer.declarePullSubscriber(
      'demo/own/out/falsify',
      kind: ChannelKind.fifo,
      capacity: 1,
    );
    for (var i = 0; i < 8; i++) {
      producer.put('demo/own/out/falsify', 'overflow$i');
    }
    // Settle time, not a race: the puts have returned and this is the window
    // in which canon's delivery thread fills the channel and parks a send.
    await Future<void>.delayed(const Duration(seconds: 2));
    if (pull.keyExpr.isEmpty) stdout.writeln('UNREACHABLE');
  }
  stdout.writeln('FIN_OVERFLOWED');

  // ⚠️ No `zd_fin_session` is shipped or declared. `Session.loanedHandle`
  // ALIASES the slot and `zd_close_session` is `void(z_owned_session_t*)` --
  // ABI-identical to `NativeFinalizerFunction` -- so the throwaway instrument
  // needs no new surface.
  NativeFinalizer(
    nativeLibrary.lookup<NativeFinalizerFunction>('zd_close_session'),
  ).attach(consumer, slotAlias.cast());
}

// ---------------------------------------------------------------------------
// Slice 13 — the TEN classes OUT of the net
// ---------------------------------------------------------------------------
//
// An exclusion nobody can observe is indistinguishable from an oversight.
// These arms make the ten absences assertable.

@pragma('vm:never-inline')
void _makeAllTenExcludedAndDrop(Session s) {
  // Every excluded class, constructed and dropped. None of them may move any
  // counter, and the counters are read PER KIND so a stray attachment to any
  // entry is visible rather than averaged away.
  final q1 = s.declareQuerier('demo/own/out/q');
  final lt = s.declareLivelinessToken('demo/own/out/lt');
  final sub = s.declareSubscriber('demo/own/out/s');
  final qa = s.declareQueryable('demo/own/out/qa');
  final ps = s.declarePullSubscriber('demo/own/out/ps', capacity: 4);
  final pq = s.declarePullQueryable(
    'demo/own/out/pq',
    kind: ChannelKind.ring,
    capacity: 4,
  );
  final pr = s.pullLivelinessGet(
    'demo/own/out/**',
    kind: ChannelKind.ring,
    capacity: 4,
  );
  // ⚠️ `AdvancedSubscriber` is the unstable API: declaring one under the stable
  // native throws, which exited this arm 255 in the stable variant's first full
  // run. So it is constructed only where the loaded native has it, and the arm
  // SAYS whether it was — the cell pins that per variant.
  final asub = ZenohFeatures.hasUnstableApi
      ? s.declareAdvancedSubscriber('demo/own/out/as')
      : null;
  stdout.writeln('FIN_OUT_ADVSUB=${asub == null ? 0 : 1}');
  if (q1.keyExpr.isEmpty ||
      lt.keyExpr.isEmpty ||
      sub.keyExpr.isEmpty ||
      qa.keyExpr.isEmpty ||
      ps.keyExpr.isEmpty ||
      pq.keyExpr.isEmpty ||
      pr.hashCode == -1 ||
      (asub != null && asub.hashCode == -1)) {
    stdout.writeln('UNREACHABLE');
  }
}

// ---------------------------------------------------------------------------
// ZDeserializer arms
// ---------------------------------------------------------------------------

ZBytes _payload() {
  final s = ZSerializer()..serializeUint8(7);
  return s.finish();
}

@pragma('vm:never-inline')
void _makeDeserializerAndDrop() {
  // Built in a callee that does not return it — the shape a caller's forgotten
  // `dispose()` actually takes.
  final d = ZDeserializer(_payload());
  if (d.deserializeUint8() != 7) stdout.writeln('UNREACHABLE');
}

@pragma('vm:never-inline')
void _makeDeserializerAndDispose() {
  final d = ZDeserializer(_payload());
  if (d.deserializeUint8() != 7) stdout.writeln('UNREACHABLE');
  d.dispose();
}

@pragma('vm:never-inline')
void _makeDeserializersAndDrop(int n) {
  for (var i = 0; i < n; i++) {
    final d = ZDeserializer(_payload());
    if (d.deserializeUint8() != 7) stdout.writeln('UNREACHABLE');
  }
}

Future<void> main(List<String> args) async {
  String opt(String name, String fallback) {
    final i = args.indexOf('--$name');
    return (i == -1 || i + 1 >= args.length) ? fallback : args[i + 1];
  }

  final arm = opt('arm', 'deser-drop');
  final count = int.parse(opt('count', '64'));

  // ⚠️ A BARE NEWLINE FIRST. The toolchain prints "Running build hooks..."
  // with no trailing newline, so without this the first marker is glued to it
  // and every `startsWith` check in HarnessOutcome misses it.
  stdout
    ..writeln()
    ..writeln('FIN_READY arm=$arm');

  // Force the library load (and therefore the mutator-thread capture) before
  // anything else, so `FIN_ON_MAIN` has a reference thread even in an arm
  // where no finalizer fires.
  ensureInitialized();
  // Which native this process loaded. The stale-native cell stages a doctored
  // library and must know the child loaded THAT one: a loader probe that found
  // an intact native elsewhere otherwise reads as "ran to completion".
  stdout.writeln('FIN_LIB=$resolvedLibraryPath');

  switch (arm) {
    case 'deser-drop':
      _makeDeserializerAndDrop();
      final round = await _pressureUntil(ZdFinKind.freeBlock, 1);
      _report(ZdFinKind.freeBlock, round: round);

    case 'attach-without-detach':
      _makeHolderAttachedTwice();
      final round = await _pressureUntil(ZdFinKind.freeBlock, 2);
      _report(ZdFinKind.freeBlock, round: round);

    case 'no-attach':
      _makeHolderNeverAttached();
      await _pressureFully();
      _report(ZdFinKind.freeBlock, round: -1);

    case 'deser-dispose':
      _makeDeserializerAndDispose();
      await _pressureFully();
      _report(ZdFinKind.freeBlock, round: -1);

    case 'deser-mass-free':
      // Every one of these is released through the FINALIZER path only. Under
      // `MALLOC_PERTURB_` a premature or double free shows up as an abort
      // rather than as plausible bytes, so reaching the success marker is the
      // assertion.
      _makeDeserializersAndDrop(count);
      final round = await _pressureUntil(ZdFinKind.freeBlock, count);
      _report(ZdFinKind.freeBlock, round: round);
      stdout.writeln('FIN_RELEASED=$count');

    case 'config-drop':
      _makeConfigAndDrop();
      final round = await _pressureUntil(ZdFinKind.config, 1);
      _report(ZdFinKind.config, round: round);

    case 'config-dispose':
      _makeConfigAndDispose();
      await _pressureFully();
      _report(ZdFinKind.config, round: -1);

    case 'config-consumed-explicit':
      await _openSessionWithExplicitConfig();
      await _pressureFully();
      _report(ZdFinKind.config, round: -1);

    case 'config-consumed-internal':
      await _openSessionWithInternalConfig();
      await _pressureFully();
      _report(ZdFinKind.config, round: -1);

    case 'config-consumed-scout':
      // The SECOND consumer of markConsumed, and CONV-5 wants the enumeration
      // rather than a representative: `Zenoh.scout(config:)` marks through the
      // same method but from a different call site, and a release-path list
      // that names only one of them is incomplete by CONV-5's own terms.
      await Zenoh.scout(config: _quietConfig(), timeoutMs: 200);
      await _pressureFully();
      _report(ZdFinKind.config, round: -1);

    case 'config-dispose-after-consume':
      // The pinned asymmetry with `ZBytes.dispose` must survive the detach:
      // disposing a config already handed to the session is a caller bug worth
      // reporting, and the detach must not quietly turn that throw into a
      // no-op.
      final c = _quietConfig();
      final s = await Session.open(config: c);
      var threw = false;
      try {
        c.dispose();
        // The pinned contract IS a StateError -- an Error subtype by the
        // package's own design -- so catching it is the assertion, not a
        // swallowed programming mistake.
        // ignore: avoid_catching_errors
      } on StateError {
        threw = true;
      }
      s.close();
      stdout.writeln('FIN_THREW=${threw ? 1 : 0}');
      await _pressureFully();
      _report(ZdFinKind.config, round: -1);

    case 'config-construct-throws':
      // ALLOCATE-LAST: the object never existed, so no finalizer can be
      // attached to it and the constructor's own free is the only release.
      // ⚠️ `Config.fromEnv()` with ZENOH_CONFIG unset was the obvious driver
      // and it INHERITS the environment: on a machine where that variable
      // happens to be set the constructor succeeds and the cell fails for a
      // reason that has nothing to do with the net. A path that cannot exist
      // throws on every host. Tests control their environment; they never
      // inherit it.
      var threw = false;
      try {
        Config.fromFile('/nonexistent/zd-own-slice4/config.json5');
      } on ZenohException {
        threw = true;
      }
      stdout.writeln('FIN_THREW=${threw ? 1 : 0}');
      await _pressureFully();
      _report(ZdFinKind.config, round: -1);

    case 'bytes-drop':
      _makeBytesAndDrop();
      final round = await _pressureUntil(ZdFinKind.bytes, 1);
      _report(ZdFinKind.bytes, round: round);

    case 'bytes-dispose':
      _makeBytesAndDispose();
      await _pressureFully();
      _report(ZdFinKind.bytes, round: -1);

    case 'bytes-consumed':
      final s = await Session.open(config: _quietConfig());
      _publishAndDrop(s, count);
      await _pressureFully();
      s.close();
      _report(ZdFinKind.bytes, round: -1);

    case 'bytes-borrowed':
      // Criterion (i) for `ZBytes`, driven: the payload's only remaining
      // holder is a live `ZDeserializer` reading from it. If the collector
      // took the bytes out from under that cursor, every read after the
      // pressure would be a use-after-free the VM cannot see.
      final payload = _payload();
      final d = ZDeserializer(payload);
      await _pressureFully();
      final v = d.deserializeUint8();
      stdout.writeln('FIN_READBACK=$v');
      _report(ZdFinKind.bytes, round: -1);
      d.dispose();
      payload.dispose();

    case 'bytes-shm':
      // An SHM-backed payload: `toBytes()` MOVES the chunk into the ZBytes, so
      // the ZBytes net is what returns it to the pool.
      //
      // ⛔ THE INSTRUMENT IS POOL EXHAUSTION THROUGH `allocGc`, NOT
      // `available` AND NOT /dev/shm. `ShmProvider.available` WAS a constant 0
      // and has since been REMOVED on that measurement ([SHM] slice 14)
      // at every lifecycle point -- the class's own dartdoc records the
      // measurement -- so branching on it is branching on a constant. And a
      // CHUNK release moves /dev/shm entries, fds and mappings by ZERO; those
      // discriminate at PROVIDER level only.
      // ⚠️ `allocGc`, never plain `alloc`: `alloc` after a release returns
      // AllocError because it does not process the deallocation queue, so a
      // cell using it goes red on correct code.
      final provider = ShmProvider(size: 65536);
      final first = provider.alloc(40960);
      if (first is! AllocOk) {
        stdout.writeln('FIN_SHM_SETUP_FAILED=$first');
        exit(2);
      }
      var payloadRef = first.buffer.toBytes();
      // CONTROL: while the payload is live the pool cannot satisfy a second
      // request of the same size.
      final whileLive = provider.allocGc(40960);
      stdout.writeln('FIN_SHM_WHILE_LIVE=${whileLive is AllocOk ? 1 : 0}');
      if (whileLive is AllocOk) whileLive.buffer.dispose();
      // Drop the payload WITHOUT disposing it, then let the net reclaim it.
      payloadRef = ZBytes.fromString('');
      if (payloadRef.hashCode == -1) stdout.writeln('UNREACHABLE');
      final round2 = await _pressureUntil(ZdFinKind.bytes, 1);
      final afterDrop = provider.allocGc(40960);
      stdout.writeln('FIN_SHM_AFTER_DROP=${afterDrop is AllocOk ? 1 : 0}');
      if (afterDrop is AllocOk) afterDrop.buffer.dispose();
      _report(ZdFinKind.bytes, round: round2);
      provider.close();

    case 'keyexpr-view-drop':
      _makeViewKeyExprAndDrop();
      final round = await _pressureUntil(ZdFinKind.freeBlock, 2);
      _report(ZdFinKind.freeBlock, round: round);

    case 'keyexpr-view-dispose':
      _makeViewKeyExprAndDispose();
      await _pressureFully();
      _report(ZdFinKind.freeBlock, round: -1);

    case 'keyexpr-owned-drop':
      final s1 = await Session.open(config: _quietConfig());
      _makeOwnedKeyExprAndDrop(s1);
      final round = await _pressureUntil(ZdFinKind.keyExpr, 1);
      // ⛔ BOTH counters, read SEPARATELY. An owned key expression wrongly put
      // on the free-only shape leaks canon's keyexpr silently and would read 1
      // on a single global counter -- passing the cell that exists to catch it.
      _report(ZdFinKind.keyExpr, round: round);
      stdout.writeln(
        'FIN_FREEBLOCK=${bindings.zd_fin_invocations(ZdFinKind.freeBlock)}',
      );
      s1.close();

    case 'keyexpr-undeclare':
      final s2 = await Session.open(config: _quietConfig());
      final k = s2.declareKeyExpr('demo/own/fin/undecl');
      s2.undeclareKeyExpr(k);
      await _pressureFully();
      _report(ZdFinKind.keyExpr, round: -1);
      stdout.writeln(
        'FIN_FREEBLOCK=${bindings.zd_fin_invocations(ZdFinKind.freeBlock)}',
      );
      s2.close();

    case 'keyexpr-construct-throws':
      // `a//b` is NOT canon and the strict door genuinely rejects it.
      // ⚠️ A lone surrogate does NOT work here and the plan says why: it
      // CONSTRUCTS, because `utf8.encode` substitutes U+FFFD before canon sees
      // a byte. On a correct implementation both view attachments would land
      // and the counter would read 2 -- the cell would go red on correct code.
      var threw = 0;
      for (final bad in const ['a//b', '']) {
        try {
          KeyExpr(bad);
        } on ZenohException {
          threw++;
        }
      }
      stdout.writeln('FIN_THREW=$threw');
      await _pressureFully();
      _report(ZdFinKind.freeBlock, round: -1);
      stdout.writeln(
        'FIN_KEYEXPR=${bindings.zd_fin_invocations(ZdFinKind.keyExpr)}',
      );

    case 'writer-drop':
      _makeWriterAndDrop();
      final round = await _pressureUntil(ZdFinKind.bytesWriter, 1);
      _report(ZdFinKind.bytesWriter, round: round);

    case 'writer-finish':
      _makeWriterAndFinish();
      await _pressureFully();
      _report(ZdFinKind.bytesWriter, round: -1);

    case 'writer-finish-dispose':
      _makeWriterFinishThenDispose();
      await _pressureFully();
      _report(ZdFinKind.bytesWriter, round: -1);

    case 'writer-abandoned':
      _makeWriterAbandonedOnError();
      final round = await _pressureUntil(ZdFinKind.bytesWriter, 1);
      _report(ZdFinKind.bytesWriter, round: round);

    case 'serializer-drop':
      _makeSerializerAndDrop();
      final round = await _pressureUntil(ZdFinKind.serializer, 1);
      _report(ZdFinKind.serializer, round: round);

    case 'serializer-finish':
      _makeSerializerAndFinish();
      await _pressureFully();
      _report(ZdFinKind.serializer, round: -1);

    case 'pub-drop-mloff':
      final sp1 = await Session.open(config: _quietConfig());
      _makePublisherAndDrop(sp1, ml: false);
      final round = await _pressureUntil(ZdFinKind.publisher, 1);
      _report(ZdFinKind.publisher, round: round);
      sp1.close();

    case 'pub-drop-mlon':
      final sp2 = await Session.open(config: _quietConfig());
      _makePublisherAndDrop(sp2, ml: true);
      await _pressureFully();
      _report(ZdFinKind.publisher, round: -1);
      sp2.close();

    case 'pub-close':
      final sp3 = await Session.open(config: _quietConfig());
      sp3.declarePublisher('demo/own/fin/pubc').close();
      await _pressureFully();
      _report(ZdFinKind.publisher, round: -1);
      sp3.close();

    case 'apub-drop-mloff':
      final sa1 = await Session.open(config: _quietConfig());
      _makeAdvancedPublisherAndDrop(sa1, ml: false);
      final round = await _pressureUntil(ZdFinKind.advancedPublisher, 1);
      _report(ZdFinKind.advancedPublisher, round: round);
      sa1.close();

    case 'apub-drop-mlon':
      final sa2 = await Session.open(config: _quietConfig());
      _makeAdvancedPublisherAndDrop(sa2, ml: true);
      await _pressureFully();
      _report(ZdFinKind.advancedPublisher, round: -1);
      sa2.close();

    case 'apub-close':
      final sa3 = await Session.open(config: _quietConfig());
      sa3.declareAdvancedPublisher('demo/own/fin/apubc').close();
      await _pressureFully();
      _report(ZdFinKind.advancedPublisher, round: -1);
      sa3.close();

    case 'pub-reach':
      final sr1 = await Session.open(config: _quietConfig());
      // The structural half of criterion (i): in the ml:off configuration
      // there is NO matchingStatus stream to hold, so the one obvious derived
      // holder does not exist here at all.
      final probe = sr1.declarePublisher('demo/own/fin/reach');
      stdout.writeln(
        'FIN_MATCHING_NULL=${probe.matchingStatus == null ? 1 : 0}',
      );
      probe.close();
      await _reachArm(
        'PUBLISHER',
        () => sr1.declarePublisher('demo/own/fin/reach2'),
      );
      sr1.close();

    case 'apub-reach':
      final sr2 = await Session.open(config: _quietConfig());
      final aprobe = sr2.declareAdvancedPublisher('demo/own/fin/areach');
      stdout.writeln(
        'FIN_MATCHING_NULL=${aprobe.matchingStatus == null ? 1 : 0}',
      );
      aprobe.close();
      await _reachArm(
        'ADVPUBLISHER',
        () => sr2.declareAdvancedPublisher('demo/own/fin/areach2'),
      );
      sr2.close();

    case 'pub-declare-throws':
      final sd = await Session.open(config: _quietConfig());
      var threw = 0;
      try {
        sd.declarePublisher('a//b');
      } on ZenohException {
        threw = 1;
      }
      stdout.writeln('FIN_THREW=$threw');
      await _pressureFully();
      _report(ZdFinKind.publisher, round: -1);
      sd.close();

    case 'querier-no-net':
      // `Querier` keeps the MARKER and gets NO finalizer, in BOTH
      // configurations. Asserted here as well as in slice 13 because this is
      // the slice a reader checks when asking why the publisher family got one
      // and the querier did not.
      final sq = await Session.open(config: _quietConfig());
      final q1 = sq.declareQuerier('demo/own/fin/q1');
      final q2 = sq.declareQuerier(
        'demo/own/fin/q2',
        enableMatchingListener: true,
      );
      q2.matchingStatus!.listen((_) {});
      if (q1.keyExpr.isEmpty || q2.keyExpr.isEmpty) {
        stdout.writeln('UNREACHABLE');
      }
      await _pressureFully();
      final total = <int>[
        for (var k = 0; k < ZdFinKind.count; k++)
          bindings.zd_fin_invocations(k),
      ];
      stdout.writeln('FIN_ALL_KINDS=${total.join(",")}');
      sq.close();

    case 'shmprov-drop':
      // Baselines FIRST, before anything SHM has happened in this process.
      final baseNames = _devShmNames();
      stdout
        ..writeln('FIN_SHM_BASE_ENTRIES=${_devShmEntries()}')
        ..writeln('FIN_SHM_BASE_FDS=${_openFds()}');
      _makeProviderAndDrop();
      final round = await _pressureUntil(ZdFinKind.shmProvider, 1);
      // Give the OS a moment to reflect the unlink before reading back.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // ⛔ SAME MACHINE-GLOBAL DEFECT AS THE ARM BELOW, MIRRORED. The count
      // assertion this replaces (`after - base <= 0`) goes red whenever a
      // SIBLING creates a segment inside the window — the opposite direction
      // to the release that produced the measured red, and just as much a
      // property of the machine rather than of this process. What is actually
      // meant is: no zenoh segment that was not here before is still here now.
      final leaked = _devShmNames()
          .difference(baseNames)
          .where((n) => n.endsWith('.zenoh'))
          .toList();
      stdout
        ..writeln('FIN_SHM_AFTER_ENTRIES=${_devShmEntries()}')
        ..writeln('FIN_SHM_AFTER_FDS=${_openFds()}')
        ..writeln('FIN_SHM_LEAKED=${leaked.length}')
        ..writeln('FIN_SHM_LEAKED_NAMES=${leaked.join(",")}');
      _report(ZdFinKind.shmProvider, round: round);

    case 'shmprov-noattach':
      // ⛔ THE FALSE-GREEN DIRECTION for the RESOURCE instrument, not for the
      // counter. A provider that is KEPT holds its segment through the whole
      // cap -- so if the entry count fell here too, the "returned to baseline"
      // reading in the arm above would be measuring process churn rather than
      // the release.
      final baseNames = _devShmNames();
      stdout.writeln('FIN_SHM_BASE_ENTRIES=${_devShmEntries()}');
      final kept = ShmProvider(size: 65536);
      await _pressureFully();
      final appeared = _devShmNames().difference(baseNames);
      stdout
        ..writeln('FIN_SHM_AFTER_ENTRIES=${_devShmEntries()}')
        ..writeln('FIN_SHM_APPEARED=${appeared.length}')
        ..writeln('FIN_SHM_APPEARED_NAMES=${appeared.join(",")}')
        // ⛔ THE MARKER SPLIT AT [SHM] slice 14, and it is a split rather than
        // a replacement. It used to read `kept.available >= 0`, which did TWO
        // jobs:
        //
        //   1. REACHABILITY -- it is a USE of `kept` after the pressure ran.
        //      Without one, `kept` can become unreachable inside the window,
        //      its finalizer can fire, and this arm SILENTLY STOPS MEASURING
        //      what it exists to measure. That is the half whose loss is
        //      invisible, and this file has a recorded instance of exactly it
        //      (an object stayed reachable, the arm reported 0, and it would
        //      have read as "the transition never happened").
        //   2. GUARD LIVENESS -- the call not throwing showed `_ensureOpen()`
        //      still passed.
        //
        // ⚠️ After the removal NO single member does both: every guarded
        // member left on the class is SIDE-EFFECTING, and a side effect inside
        // a measurement window is not acceptable here. So job 1 stays, as this
        // file's own non-side-effecting idiom; job 2 moved to the re-homed
        // closed-provider cells in `shm_provider_test.dart`, which is a better
        // home for it than a marker inside a resource arm.
        ..writeln('FIN_SHM_KEPT_OK=${kept.hashCode == -1 ? 0 : 1}');
      _report(ZdFinKind.shmProvider, round: -1);

      // ⭐ ATTRIBUTION BY BEHAVIOUR, NOT BY NAME. A sibling process can create
      // a `.zenoh` segment inside our window and land in `appeared` — that is
      // the false-GREEN direction, and a name pattern cannot exclude it. What
      // a sibling's segment will NOT do is vanish in step with OUR `close()`.
      // Requiring at least one appeared entry to disappear exactly here pairs
      // the creation with the release on the same named entity, which is as
      // close to attribution as this instrument can get.
      kept.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final stillThere = _devShmNames();
      final vanished = appeared.difference(stillThere);
      stdout
        ..writeln('FIN_SHM_VANISHED=${vanished.length}')
        ..writeln('FIN_SHM_VANISHED_NAMES=${vanished.join(",")}');

    case 'shmprov-close':
      ShmProvider(size: 65536).close();
      await _pressureFully();
      _report(ZdFinKind.shmProvider, round: -1);

    case 'shmprov-live-child':
      // CRITERION (iii) as a cell: the provider's release must not change the
      // contract of any live Dart object. `close()` calls the SAME
      // `zd_shm_provider_drop` the finalizer would.
      final prov = ShmProvider(size: 65536);
      final r = prov.alloc(1024);
      if (r is! AllocOk) {
        stdout.writeln('FIN_SHM_SETUP_FAILED=$r');
        exit(2);
      }
      final buf = r.buffer;
      prov.close();
      buf.write(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
      final len = buf.length;
      final payload = buf.toBytes();
      final bytes = payload.toBytes();
      stdout
        ..writeln('FIN_SHM_CHILD_LEN=$len')
        ..writeln('FIN_SHM_CHILD_FIRST=${bytes[0]}')
        ..writeln('FIN_SHM_CHILD_SHM=${payload.isShmBacked ? 1 : 0}');
      payload.dispose();

    case 'shmprov-live-bytes':
      // The same, one level further: a derived `ZBytes` outliving the provider
      // must still read byte-exactly AND still publish.
      final prov2 = ShmProvider(size: 65536);
      final r2 = prov2.alloc(256);
      if (r2 is! AllocOk) {
        stdout.writeln('FIN_SHM_SETUP_FAILED=$r2');
        exit(2);
      }
      r2.buffer.write(List<int>.filled(256, 7));
      final moved = r2.buffer.toBytes();
      prov2.close();
      final content = moved.toBytes();
      final sess = await Session.open(config: _quietConfig());
      var published = 0;
      try {
        sess.putBytes('demo/own/fin/shmp', moved);
        published = 1;
      } on ZenohException {
        published = 0;
      }
      stdout
        ..writeln('FIN_SHM_BYTES_LEN=${content.length}')
        ..writeln('FIN_SHM_BYTES_FIRST=${content[0]}')
        ..writeln('FIN_SHM_BYTES_ALL7=${content.every((b) => b == 7) ? 1 : 0}')
        ..writeln('FIN_SHM_PUBLISHED=$published');
      sess.close();

    case 'shmprov-construct-throws':
      // A pool below the Talc minimum is refused cleanly -- the constructor is
      // a straight return-code pass-through, so this surfaces as an exception
      // rather than as canon's own segfault.
      var threw = 0;
      try {
        ShmProvider(size: 1);
      } on ZenohException {
        threw = 1;
      }
      stdout.writeln('FIN_THREW=$threw');
      await _pressureFully();
      _report(ZdFinKind.shmProvider, round: -1);

    case 'shmmut-fresh-drop':
      final pv = ShmProvider(size: _shmPool);
      // CONTROL FIRST, while the buffer is still held: the pool must NOT
      // satisfy a second chunk. Without this the success below is equally
      // consistent with a pool that was never exhausted.
      var held = pv.alloc(_shmChunk);
      if (held is! AllocOk) {
        stdout.writeln('FIN_SHM_SETUP_FAILED=$held');
        exit(2);
      }
      stdout.writeln('FIN_SHM_WHILE_LIVE=${_poolFree(pv)}');
      held = const AllocError(AllocErrorKind.other);
      final round = await _pressureUntil(ZdFinKind.shmMut, 1);
      stdout
        ..writeln('FIN_SHM_AFTER_DROP=${_poolFree(pv)}')
        ..writeln(
          'FIN_FREEBLOCK='
          '${bindings.zd_fin_invocations(ZdFinKind.freeBlock)}',
        );
      _report(ZdFinKind.shmMut, round: round);
      pv.close();

    case 'shmmut-written-drop':
      // ⛔ RETARGETED 2026-09-02 (unit [SHM] shared-memory-lifetime,
      // slice 4). This arm was `shmmut-escaped-drop` and its subject was THE
      // ESCAPE: a caller held the raw `data` pointer, so the net could NOT
      // free the chunk under it -- that would have turned the leak into a
      // use-after-free -- and downgraded to slot-only instead. It asserted
      // the chunk stayed PINNED, which is the leak this unit closes.
      //
      // Nothing in the tree escapes a pointer any more: every caller was
      // migrated onto the copying `write` in this slice, and slice 5 removes
      // `ShmMutBuffer.data` outright, at which point the downgrade transition
      // this arm measured is unreachable and then gone. Recorded rather than
      // deleted so the work is traceable: slice 5 is where it went.
      //
      // What it drives now is the SAME lifecycle -- allocate, put bytes in,
      // drop the handle without disposing -- through `write`. The reading
      // INVERTS, and that inversion is the unit's product claim: because
      // `write` does not downgrade, the full drop+free entry fires and the
      // chunk goes back to the pool instead of being pinned forever.
      final pv2 = ShmProvider(size: _shmPool);
      var r3 = pv2.alloc(_shmChunk);
      if (r3 is! AllocOk) {
        stdout.writeln('FIN_SHM_SETUP_FAILED=$r3');
        exit(2);
      }
      // CONTROL FIRST, while the buffer is still live: the pool must NOT
      // satisfy a second full-size chunk, or the success below is equally
      // consistent with a pool that was never exhausted.
      stdout.writeln('FIN_SHM_WHILE_LIVE=${_poolFree(pv2)}');
      r3.buffer.write(<int>[9, 8, 7, 6]);
      r3 = const AllocError(AllocErrorKind.other);
      final round2 = await _pressureUntil(ZdFinKind.shmMut, 1);
      stdout
        ..writeln('FIN_SHM_AFTER_DROP=${_poolFree(pv2)}')
        ..writeln(
          'FIN_FREEBLOCK='
          '${bindings.zd_fin_invocations(ZdFinKind.freeBlock)}',
        );
      _report(ZdFinKind.shmMut, round: round2);
      pv2.close();

    case 'shmmut-consumed':
      // `toBytes()` moves the chunk into a ZBytes that has its own net, so
      // what is left here is the slot.
      final pv3 = ShmProvider(size: _shmPool);
      var r4 = pv3.alloc(_shmChunk);
      if (r4 is! AllocOk) {
        stdout.writeln('FIN_SHM_SETUP_FAILED=$r4');
        exit(2);
      }
      r4.buffer.write(<int>[1, 1, 2, 3]);
      final kept2 = r4.buffer.toBytes();
      r4 = const AllocError(AllocErrorKind.other);
      final round3 = await _pressureUntil(ZdFinKind.freeBlock, 1);
      final read = kept2.toBytes();
      stdout
        ..writeln('FIN_SHM_PAYLOAD=${read.sublist(0, 4).join(",")}')
        ..writeln(
          'FIN_SHMMUT=${bindings.zd_fin_invocations(ZdFinKind.shmMut)}',
        );
      _report(ZdFinKind.freeBlock, round: round3);
      kept2.dispose();
      pv3.close();

    // ⛔ `shmmut-dispose-escaped` WAS RETIRED HERE, 2026-09-02 (slice 5), and
    // this note is the trace it existed. It disposed a buffer whose `data`
    // pointer had escaped -- the third state of a net that now has two. Slice
    // 4 migrated its fill to `write`, at which point it measured exactly what
    // `shmmut-dispose-fresh` measures and its NAME kept a promise its body no
    // longer could; slice 5 removed the getter, so the state it was named for
    // is unreachable. It is not replaced: `dispose()` detaching whatever shape
    // is attached is shape-agnostic, and both reachable shapes are covered
    // below.
    //
    // `shmmut-dispose-twice` is NEW at slice 5, and is not a rename of it. The
    // retired arm disposed once from a state that no longer exists; this one
    // disposes TWICE from a state that does, which is the claim the unit's own
    // re-armed net makes newly worth driving -- the net now releases the chunk,
    // so a second release landing on it would be a double free rather than the
    // no-op it used to be.
    case 'shmmut-dispose-fresh':
    case 'shmmut-dispose-consumed':
    case 'shmmut-dispose-twice':
      final pv4 = ShmProvider(size: _shmPool);
      final r5 = pv4.alloc(_shmChunk);
      if (r5 is! AllocOk) {
        stdout.writeln('FIN_SHM_SETUP_FAILED=$r5');
        exit(2);
      }
      final b5 = r5.buffer;
      if (arm == 'shmmut-dispose-consumed') {
        b5.toBytes().dispose();
        b5.dispose();
      } else if (arm == 'shmmut-dispose-twice') {
        // Written FIRST, so the chunk-releasing net is the one attached --
        // which is the whole point. Before slice 5 a written buffer was in
        // the slot-only shape and a second release could not have reached a
        // chunk; now it could, so the idempotence is load-bearing rather
        // than incidental.
        b5
          ..write(<int>[7, 7, 7, 7])
          ..dispose()
          ..dispose();
      } else {
        b5.dispose();
      }
      await _pressureFully();
      stdout.writeln(
        'FIN_FREEBLOCK=${bindings.zd_fin_invocations(ZdFinKind.freeBlock)}',
      );
      _report(ZdFinKind.shmMut, round: -1);
      pv4.close();

    case 'shmmut-write-five-times':
      // ⛔ RETARGETED 2026-09-02 with `_allocAndWriteFiveTimes` above; the
      // note on that function carries the reason and names slice 5.
      final pv6 = ShmProvider(size: _shmPool);
      _allocAndWriteFiveTimes(pv6);
      final round4 = await _pressureUntil(ZdFinKind.shmMut, 1);
      stdout
        ..writeln(
          'FIN_FREEBLOCK='
          '${bindings.zd_fin_invocations(ZdFinKind.freeBlock)}',
        )
        ..writeln('FIN_SHM_AFTER_DROP=${_poolFree(pv6)}');
      _report(ZdFinKind.shmMut, round: round4);
      pv6.close();

    case 'shmmut-cycle':
      // Criterion (iii) in the child -> parent direction: chunks released by
      // the net are genuinely returned to the pool, N times over.
      // ⚠️ The pool holds ONE chunk of this size, so each cycle depends on
      // the PREVIOUS one having been reclaimed by the net. An earlier cut
      // applied a single pressure round between allocations and failed at
      // i=1 -- the chunk had not been released yet, which is a statement
      // about GC timing rather than about the net. Each cycle now WAITS for
      // the counter to reach i+1, bounded by the same round cap.
      final pv7 = ShmProvider(size: _shmPool);
      var cycles = 0;
      for (var i = 0; i < count; i++) {
        _allocAndDrop(pv7);
        final got = await _pressureUntil(ZdFinKind.shmMut, i + 1);
        if (got < 0) {
          stdout.writeln('FIN_SHM_CYCLE_STALLED_AT=$i');
          break;
        }
        cycles++;
      }
      // The pool must still satisfy a full-size request after N cycles, which
      // is criterion (iii) in the child -> parent direction.
      stdout
        ..writeln('FIN_SHM_CYCLES=$cycles')
        ..writeln('FIN_SHM_POOL_FREE=${_poolFree(pv7)}');
      _report(ZdFinKind.shmMut, round: -1);
      pv7.close();

    case 'knp-orphaned':
    case 'knp-delivered':
      // ONE session: the queryable and the getter must find each other, and
      // two quiet sessions in one process cannot discover each other.
      final ks = await Session.open(config: _quietConfig());
      final rp = ReceivePort();
      var delivered = 0;
      if (arm == 'knp-delivered') {
        // THE CONTROL ARM: the port IS drained and every query is disposed,
        // so nothing should be outstanding at exit. Without it, a nonzero
        // reading in the other arm could be background noise at that size
        // class rather than orphaned clones.
        rp.listen((dynamic m) {
          if (m is! List) return;
          delivered++;
          bindings.zd_query_drop(Pointer<Uint8>.fromAddress(m[0] as int));
        });
      }
      final slot = _declareQueryableOnPort(
        ks,
        'demo/own/fin/knp',
        rp.sendPort.nativePort,
      );
      stdout.writeln('KNP_QUERY_SIZEOF=${bindings.zd_query_sizeof()}');
      for (var i = 0; i < count; i++) {
        ks.get('demo/own/fin/knp').listen((_) {}, onError: (Object _) {});
      }
      // Let the posts land in the port's queue.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      // ⛔ In the `knp-orphaned` arm the port was NEVER LISTENED, so every
      // posted message is still queued here and is destroyed undelivered by
      // this close. That is the delivered-then-destroyed hole, driven
      // deterministically rather than raced.
      rp.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      stdout.writeln('KNP_DELIVERED=$delivered');
      bindings.zd_queryable_drop(slot.cast());
      calloc.free(slot);
      ks.close();
      stdout.writeln('KNP_SENT=$count');

    case 'knp-shipped':
      // ⭐ THE DECISIVE ARM. The bare-port arms above prove the hole EXISTS by
      // never listening — an artificial shape. What decides adoption is
      // whether it is REACHABLE THROUGH THE SHIPPED API, where `QueryChannel`
      // listens immediately and `closeAndDrain()` disposes whatever reached
      // the channel but not a consumer.
      //
      // So: a real `Queryable`, N queries in flight, closed promptly. Anything
      // the VM had not yet delivered when the port closed is orphaned and
      // `closeAndDrain` cannot see it.
      final ss = await Session.open(config: _quietConfig());
      final qa = ss.declareQueryable('demo/own/fin/knps');
      var seen = 0;
      qa.stream.listen((q) {
        seen++;
        q.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (var i = 0; i < count; i++) {
        ss.get('demo/own/fin/knps').listen((_) {}, onError: (Object _) {});
      }
      // NO await before the close: this is the tightest realistic race, a
      // caller closing the queryable while queries are still arriving.
      qa.close();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      stdout
        ..writeln('KNP_SHIPPED_SEEN=$seen')
        ..writeln('KNP_SENT=$count');
      ss.close();

    case 'out-of-net':
      // `Session` is the ninth excluded class and is the one this arm holds
      // (everything else needs it); `Query` is the tenth and is covered by
      // slice 13's own hook cell, which needs a live query round-trip.
      final os = await Session.open(config: _quietConfig());
      _makeAllTenExcludedAndDrop(os);
      await _pressureFully();
      final all = <int>[
        for (var k = 0; k < ZdFinKind.count; k++)
          bindings.zd_fin_invocations(k),
      ];
      stdout.writeln('FIN_ALL_KINDS=${all.join(",")}');
      os.close();

    case 'gc-sub':
      // ⭐ THE REGRESSION GUARD FOR THE 27th PASS'S CENTRAL FINDING. The
      // idiomatic shape retains NO handle -- `declareSubscriber(k).stream`
      // -- so the wrapper is unreferenced from the first line. If a
      // `Subscriber` finalizer were ever added, this goes 3 -> 0.
      final gs = await Session.open(config: _quietConfig());
      var got = 0;
      gs.declareSubscriber('demo/own/out/gc').stream.listen((_) => got++);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final pub = gs.declarePublisher('demo/own/out/gc');
      for (var i = 0; i < 3; i++) {
        pub.put('m$i');
        await _pressureRound(i);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      stdout.writeln('FIN_DELIVERED=$got');
      pub.close();
      gs.close();

    case 'querier-inflight-guard':
      // ⭐ THE SHAPE THAT DISQUALIFIED `Querier`, as a standing guard. The
      // querier itself is unreferenced while its `get()` is in flight; a
      // finalizer there would undeclare it and terminate the get with zero
      // replies.
      final qs = await Session.open(config: _quietConfig());
      final qaq = qs.declareQueryable('demo/own/out/qig');
      qaq.stream.listen((q) async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        q
          ..reply('demo/own/out/qig', 'late')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      var replies = 0;
      // The querier is NOT retained: only the stream is.
      qs
          .declareQuerier('demo/own/out/qig')
          .get()
          .listen(
            (_) => replies++,
            onError: (Object _) {},
          );
      await _pressureFully();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final all2 = <int>[
        for (var k = 0; k < ZdFinKind.count; k++)
          bindings.zd_fin_invocations(k),
      ];
      stdout
        ..writeln('FIN_REPLIES=$replies')
        ..writeln('FIN_ALL_KINDS=${all2.join(",")}');
      qaq.close();
      qs.close();

    case 'leak-at-shutdown':
      // The shutdown-guarantee cell. Leaks IN-NET, PORT-FREE objects and then
      // simply returns from main. The counters cannot be read from Dart after
      // the isolate group is gone, so they are printed by a native destructor
      // in the LD_PRELOAD helper instead.
      _makeConfigAndDrop();
      _makeViewKeyExprAndDrop();
      stdout.writeln('FIN_MAIN_RETURNS');
      await stdout.flush();
      return; // NOT exit(0) -- a normal return is what reaches shutdown.

    case 'session-falsifier':
    case 'session-falsifier-control':
      // ⚠️ A-2's NAMED FALSIFIER, RUN. The hypothesis: a `Session` finalizer
      // is session-first by construction for every child, and session-first
      // under a pull channel in overflow is the measured freeze -- here on the
      // finalizer thread, which would freeze the isolate GROUP rather than one
      // mutator.
      //
      // ⛔ THE THREAD IS PART OF THE RESULT, NOT DECORATION. A freeze and a
      // mutator stall inside GC read IDENTICALLY on a stopwatch. The 28th pass
      // measured this VM running finalizer callbacks on the MUTATOR, so a
      // freeze with on_main=1 confirms a RELATED BUT DISTINCT hypothesis from
      // the one A-2 states, and must be reported as such.
      //
      // ⚠️ NO `zd_fin_session` IS SHIPPED OR DECLARED. This attaches
      // `zd_close_session` directly, which is possible because
      // `Session.loanedHandle` ALIASES the slot and `zd_close_session` is
      // `void(z_owned_session_t*)` -- ABI-identical to
      // `NativeFinalizerFunction`. A throwaway instrument behind a harness
      // arm, never production surface.
      // ⛔ THE SETUP RUNS IN A CALLEE THAT RETURNS NOTHING, and the second
      // cut of this arm got that wrong too. `Session implements Finalizable`,
      // and `Finalizable`'s documented semantic KEEPS `this` ALIVE to the end
      // of the method that uses it -- so with the session in the switch case's
      // own scope the finalizer COULD NOT FIRE, and the arm reported
      // "SURVIVED" while proving nothing. That is the exact false green this
      // whole seed exists to catch, produced by the very marker it ships.
      //
      // ⚠️ TWO SESSIONS OVER TCP, not one -- the FIRST cut got THAT wrong. With
      // a single session the Dart producer's `put()` blocks on the full fifo
      // and the harness never reaches the attach, measuring the fifo's
      // producer-blocking contract instead of the hypothesis. The shipped
      // `fifo_close_harness` uses a producer/consumer pair for this reason:
      // the puts return and canon's DELIVERY thread parks filling the channel.
      final hookPath = opt('hook', '');
      _Hook? hook;
      if (hookPath.isNotEmpty) {
        hook = _Hook(DynamicLibrary.open(hookPath));
        stdout.writeln('FIN_HOOK_RC=${hook.install()}');
      }
      // ⛔ THE CONTROL ARM IS NOT OPTIONAL HERE. Without the pull channel the
      // same shape must show the finalizer FIRING -- otherwise a zero in the
      // treatment arm says only "sessions are not collected in this harness",
      // which is a statement about the harness and not about the hypothesis.
      await _falsifierSetup(withPullChannel: arm == 'session-falsifier');
      stdout.writeln('FIN_ATTACHED');
      // ⛔ RESET HERE, AFTER THE ATTACH -- NOT AFTER install(). The evidence
      // this arm reads is, in its own words, "a post AFTER THE ATTACH", and
      // the reset has to draw that line.
      //
      // It used to sit immediately after install(), which was equivalent while
      // opening a session posted NOTHING. Since `Session.open` was offloaded it
      // posts exactly once per call to deliver its completion -- and this arm
      // opens TWO sessions over TCP. Measured: the control arm reported
      // FIN_HOOK_POSTS=2, which the driving cell reads as "the finalizer
      // fired" and escalates on. Those two posts were the two OPENS.
      //
      // ⚠️ That is a false positive that INVERTS the finding: it would have
      // reported A-2 as drivable, on evidence that has nothing to do with a
      // finalizer.
      hook?.reset();
      // ⛔ From here the PARENT's deadline is the bound. If A-2's hypothesis
      // holds, this never returns.
      await _pressureFully();
      stdout.writeln('FIN_SURVIVED');
      if (hook != null) {
        // ⭐ WHETHER IT FIRED AT ALL. `z_close` drops closures that post, so a
        // post after the attach is the evidence the finalizer ran -- and the
        // hook's thread reading is what separates "froze on the finalizer
        // thread" from "stalled the mutator inside GC", which a stopwatch
        // cannot.
        stdout
          ..writeln('FIN_HOOK_POSTS=${hook.posts()}')
          ..writeln('FIN_HOOK_ON_MAIN=${hook.lastOnMain()}');
        hook.uninstall();
      }

    case 'mirror-check':
      // The Dart mirror of the C kind codes, read back through the counter's
      // own domain: every declared kind must be addressable, and one past the
      // end must not be.
      stdout.writeln('FIN_MIRROR_COUNT=${ZdFinKind.count}');
      for (var k = 0; k < ZdFinKind.count; k++) {
        final v = bindings.zd_fin_invocations(k);
        stdout.writeln('FIN_KIND_OK=$k value=$v');
      }

    case _:
      stdout.writeln('FIN_UNKNOWN_ARM=$arm');
      exit(2);
  }

  stdout
    ..writeln('FIN_MARKER_OK')
    ..writeln('FIN_DONE');
  await stdout.flush();
  exit(0);
}
