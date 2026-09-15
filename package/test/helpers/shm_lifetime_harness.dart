// The bounded-subprocess arms for the SHM lifetime cells — and the shared
// cycle vocabulary the in-process cells run too.
//
// ---------------------------------------------------------------------------
// ⛔ WHY THE TWO LEAKING ARMS DO NOT RUN IN THE SUITE PROCESS
// ---------------------------------------------------------------------------
//
// The leak these arms measure is PERMANENT FOR THE LIFE OF THE PROCESS, and
// that is not an inference — it is what the shim states about itself.
// `src/zenoh_dart.h:1729-1732`: releasing a provider does NOT invalidate its
// children, because the segment is refcounted by the chunks. The shipped
// `shmprov-live-child` arm in `test/helpers/finalizer_harness.dart:1115`
// drives exactly that: a buffer written, the provider closed, and the payload
// still readable and publishable afterwards.
//
// So closing the provider cannot reclaim a segment a chunk still pins, and no
// `tearDown` can take it back either. Each provider-level cycle here strands a
// whole 65536-byte pool and the chunk-level arm strands one.
//
// That budget is not free. The ceiling on live SHM is the process
// `RLIMIT_MEMLOCK` — 8192 kB == 8388608 bytes on this host — and these two
// arms stay RED from the slice that adds them until the slice that fixes the
// defect, so every full-suite run in between would carry their stranded
// segments for the rest of the run. A later slice of this same unit has to
// account for the suite process's own locked bytes and attribute them per
// file; cells that permanently consume that budget would corrupt that
// measurement BY CONSTRUCTION. And they would be doing to the suite precisely
// what this unit's own documentation will tell users not to do to their
// programs.
//
// In a child, the locked bytes die with the child.
//
// ⚠️ THIS IS NOT A WAY OF AFFORDING A SHORTER PRESSURE CAP. Both arms run the
// FULL round cap in the child. A zero-expecting arm that stops short of the
// cap has weakened the instrument, not the runtime.
//
// ---------------------------------------------------------------------------
// WHAT THIS FILE ALSO IS
// ---------------------------------------------------------------------------
//
// The four cycles and the pressure rounds are PUBLIC here rather than private
// to either side, because the child's leaking arms and the suite process's
// control cells have to run the IDENTICAL shape. A control that differed from
// the thing it controls in any way other than the release would not be a
// control.
//
// ⚠️ The pressure rounds are the shape `test/helpers/finalizer_harness.dart`
// lines 55-90 measured, cited rather than reinvented — but they are NOT shared
// with it. That copy is private and runs in a subprocess where it is the only
// thing in the process; hoisting it would mean editing the helper every
// finalizer cell of the [OWN] seed runs behind, for a unit that ships no
// change to it. A later slice that needs the same rounds in a third place is
// the right point to hoist.
//
// ---------------------------------------------------------------------------
// FAILURE REPORTING IN THE CHILD
// ---------------------------------------------------------------------------
//
// `sweepToRefusal` and the unwrap below reach for `fail`, so an unexpected
// state throws a `TestFailure` that nothing catches: the child dies non-zero
// with the message on stderr, the parent captures it, and the cell's exit-code
// assertion reports it with the whole transcript attached. An arm that cannot
// measure therefore FAILS rather than printing a plausible number.
//
// Every marker printed here starts with `SHM_`, which is registered in
// `test/helpers/bounded_subprocess.dart`. That registration is what makes a
// FROZEN child diagnosable — "reached SHM_CHUNK_BASELINE and no further" is a
// different diagnosis from "never started".
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/finalizers.dart' show ZdFinKind;
import 'package:zenoh_dart/src/native_lib.dart' show bindings;
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'shm_locked_bytes.dart';

/// The pool every provider in this unit is built at — the failing suite's own
/// size, and the size the whole unit was calibrated at.
const int shmPoolBytes = 65536;

/// The chunk size every allocation asks for. A fresh pool yields SEVEN.
const int shmChunkBytes = 8192;

/// How many bytes each write actually touches.
///
/// The write has to be REAL. Before slice 5 the defect was triggered by
/// READING `data`, and a cycle that took the pointer and never used it would
/// have been a different program to a reader even though it measured the
/// same. The cycles now write through `write`, and a real write is still what
/// they claim to do.
const int shmWrittenBytes = 16;

/// How many create/allocate/close cycles a provider-level arm runs.
///
/// Eight, and the ceiling is arithmetic rather than taste: a leaking cycle
/// strands a whole 65536-byte pool, and `RLIMIT_MEMLOCK` on this host is
/// 8388608 bytes of which 1310720 is the one-time lazy lock. Eight strands
/// 524288 — far enough from zero that no threshold has to be tuned, and small
/// enough that the arm cannot run itself out of budget.
const int shmProviderCycles = 8;

/// The round cap on collection pressure.
///
/// The same 120 the finalizer harness uses (`kRoundCap`), and it is a HARD
/// bound: nothing in this unit waits on a finalizer without one. An unbounded
/// wait-for-condition converts a defect into a frozen serial suite, which is
/// the most expensive failure available.
const int shmRoundCap = 120;

/// Unwraps an [AllocResult] the caller requires to have succeeded.
///
/// The exhaustive `switch` with no `default` arm is this repo's SHM
/// convention (`test/shm_provider_test.dart`): report the discriminant canon
/// returned, rather than crashing on a null three lines later.
ShmMutBuffer shmExpectOk(AllocResult result) => switch (result) {
  AllocOk(:final buffer) => buffer,
  AllocError(:final kind) => fail('expected AllocOk, got AllocError($kind)'),
  LayoutError(:final kind) => fail('expected AllocOk, got LayoutError($kind)'),
};

/// The CHUNK-level reading: how many chunks the pool still yields.
///
/// A thin naming of `sweepToRefusal` at this unit's pool and chunk size, so
/// that no cell restates the two numbers and they cannot drift apart.
int shmSweep(ShmProvider provider) =>
    sweepToRefusal(provider, poolBytes: shmPoolBytes, chunk: shmChunkBytes);

// ---------------------------------------------------------------------------
// THE FOUR CYCLES
// ---------------------------------------------------------------------------
//
// ⚠️ EVERY ONE OF THEM IS `vm:never-inline` AND RETURNS NOTHING. The buffer has
// to die with the callee. An earlier cut of the finalizer harness kept its
// buffer in the caller's own scope, where it was still reachable when the
// pressure ran and nothing was ever collected — that arm read 0 and would have
// been reported as "the transition never happened".

/// Allocates, writes through `write`, and FORGETS the buffer.
///
/// ⛔ **REWRITTEN AT SLICE 5, AND THE REWRITE IS NAMED RATHER THAN HIDDEN.**
/// Until slice 5 the fill ran through `buffer.data`, whose getter downgraded
/// the safety net to slot-only — so nothing was left that could reclaim the
/// chunk, and the two cells driving this cycle were RED. Slice 5 removed the
/// getter; `write` copies and does not downgrade, so the chunk-releasing
/// finalizer stays attached and the same cells are GREEN.
///
/// ⚠️ **What the green is attributable to, stated because it is easy to get
/// wrong:** the closure comes from the COPYING ACCESSOR, which has not
/// downgraded the net since slice 3. Removing `data` is what makes the closure
/// **irreversible** — it deletes the surface through which any caller could
/// re-open it. The deletion did not itself move these readings.
@pragma('vm:never-inline')
void shmAllocWriteAndForget(ShmProvider provider) {
  shmExpectOk(
    provider.allocGc(shmChunkBytes),
  ).write(List<int>.generate(shmWrittenBytes, (i) => i & 0xff));
}

/// Allocates, writes through `write`, and RELEASES the buffer explicitly.
///
/// The control: identical in every respect except the release. ⭐ Measured at
/// slice 2 to be a REAL control -- swapping its cycle for the forgetting one
/// made it fail at `AllocError(outOfMemory)` on the eighth allocation, before
/// the sweep was even reached.
@pragma('vm:never-inline')
void shmAllocWriteAndDispose(ShmProvider provider) {
  shmExpectOk(provider.allocGc(shmChunkBytes))
    ..write(List<int>.generate(shmWrittenBytes, (i) => i & 0xff))
    ..dispose();
}

/// Allocates, writes, moves the chunk out with `toBytes`, releases the
/// payload, and forgets the buffer.
@pragma('vm:never-inline')
void shmAllocWriteToBytesAndRelease(ShmProvider provider) {
  final buffer = shmExpectOk(provider.allocGc(shmChunkBytes))
    ..write(List<int>.generate(shmWrittenBytes, (i) => i & 0xff));
  buffer.toBytes().dispose();
}

/// Allocates and forgets, with NEITHER a write nor a release.
///
/// Nothing is written and nothing is converted, so the net is never downgraded
/// and the chunk-releasing finalizer is the one attached. ⚠️ Before slice 5
/// this was the ONLY shape with that property; now every unconverted buffer
/// has it, which is the whole point of the unit.
@pragma('vm:never-inline')
void shmAllocAndForget(ShmProvider provider) {
  final buffer = shmExpectOk(provider.allocGc(shmChunkBytes));
  if (buffer.length != shmChunkBytes) stdout.writeln('UNREACHABLE');
}

/// Creates a provider, runs [body] against it, and closes it.
@pragma('vm:never-inline')
void shmProviderCycle(void Function(ShmProvider) body) {
  final provider = ShmProvider(size: shmPoolBytes);
  body(provider);
  provider.close();
}

/// Pays the one-time 1.25 MiB lazy lock before a provider-level baseline.
///
/// It is the FIRST ALLOCATION in a process that locks it, not the first
/// provider, so this allocates and releases. A baseline taken before it reads
/// 1310720 bytes low, and the cell then sees a jump it cannot explain
/// (measured and recorded in `test/helpers/shm_locked_bytes.dart`).
void shmWarmUpTheLazyLock() {
  final provider = ShmProvider(size: shmPoolBytes);
  try {
    shmExpectOk(provider.allocGc(shmChunkBytes)).dispose();
  } finally {
    provider.close();
  }
}

/// One round of allocation pressure.
///
/// The shape measured to fire a finalizer on round 1 in 4 of 4 runs. The
/// `await` is load-bearing: the collector needs an event-loop turn, and a
/// tight synchronous loop starves it.
Future<void> shmPressureRound(int i) async {
  final ballast = <List<int>>[];
  for (var j = 0; j < 32; j++) {
    ballast.add(List<int>.filled(1 << 18, i + j));
  }
  // Touch it so the allocation cannot be elided.
  if (ballast.last.last == -1) stdout.writeln('UNREACHABLE');
  await Future<void>.delayed(Duration.zero);
}

/// Runs the FULL cap regardless — the shape a ZERO-EXPECTING arm needs.
///
/// An arm claiming "this is never reclaimed" has to give the tree every round
/// it has before saying so, or its reading reads as "we did not wait long
/// enough".
Future<void> shmPressureFully() async {
  for (var round = 1; round <= shmRoundCap; round++) {
    await shmPressureRound(round);
  }
}

/// This process's locked bytes, or a marked exit.
///
/// ⛔ Never a silent `0`: `0` is exactly what a leaked-nothing run looks like,
/// so an unavailable instrument reported as a number would make the leaking
/// arm pass.
int _lockedOrExit() {
  final reading = readLockedBytes();
  if (reading is LockedBytesOk) return reading.bytes;
  stdout.writeln(
    'SHM_UNAVAILABLE=${(reading as LockedBytesUnavailable).reason}',
  );
  exit(3);
}

/// CHUNK level: one provider held open across the whole cycle.
///
/// ⛔ The provider is never destroyed here. A cycle that closed it every round
/// would be measuring PROVIDER level under a chunk-level name.
Future<void> _chunkForgetArm() async {
  final provider = ShmProvider(size: shmPoolBytes);
  final baseline = shmSweep(provider);
  stdout.writeln('SHM_CHUNK_BASELINE=$baseline');

  shmAllocWriteAndForget(provider);
  await shmPressureFully();

  final after = shmSweep(provider);
  stdout.writeln('SHM_CHUNK_AFTER=$after');
  provider.close();
  stdout.writeln('SHM_DONE');
}

/// PROVIDER level: a fresh provider created and closed every round.
///
/// That is what makes the reading move at all — a retained CHUNK does not move
/// `VmLck`; a segment a retained chunk keeps alive past its provider's close
/// does.
Future<void> _providerForgetArm() async {
  shmWarmUpTheLazyLock();
  final baseline = _lockedOrExit();
  stdout.writeln('SHM_LOCKED_BASELINE=$baseline');

  for (var i = 0; i < shmProviderCycles; i++) {
    shmProviderCycle(shmAllocWriteAndForget);
  }
  await shmPressureFully();

  final after = _lockedOrExit();
  stdout
    ..writeln('SHM_LOCKED_AFTER=$after')
    ..writeln('SHM_DONE');
}

/// The recognisable patterns the aliasing arms write. Distinct, and none of
/// them 0 or 0xFF — a reading of either of those is as likely to be untouched
/// memory as a real write.
const int shmPatternVictim = 0x5A;
const int shmPatternEvictor = 0x33;
const int shmPatternSecond = 0x6C;

/// The half-pool request that forces an eviction.
///
/// Arithmetic, not taste: two of these cannot both fit in [shmPoolBytes], so a
/// second one succeeding is only possible by displacing the first. That is what
/// makes the eviction FORCED rather than hoped for.
const int shmEvictionRequest = 40960;

/// Allocates, writes a recognisable pattern, and FORGETS the buffer.
///
/// Separate from [shmAllocWriteAndForget] because the pattern is the point:
/// these arms ask whether a specific byte value turns up somewhere it should
/// not, so the value has to be chosen rather than incidental.
///
/// ⚠️ `allocGc`, NEVER plain `alloc` -- and this cost a red before it was
/// obeyed. `alloc` does not process the deallocation queue, so the first call
/// after any release comes back `AllocError(outOfMemory)` on a pool that
/// demonstrably has room. The trap is documented at
/// `test/helpers/finalizer_harness.dart:428-436`; reading it is not the same
/// as applying it.
@pragma('vm:never-inline')
void shmAllocPatternAndForget(ShmProvider provider, int size, int pattern) {
  shmExpectOk(provider.allocGc(size)).write(List<int>.filled(32, pattern));
}

/// ⛔ BOTH-WAYS CALIBRATION FOR THE REUSE OBSERVABLE, performed by hand at
/// slice 6 (temporary edit, measured, reverted; the restored file's sha256
/// matched the backup byte for byte). A leak instrument shown only to read
/// "clean" on clean code has not been shown to be an instrument.
///
///   * SHIPPED TREE:     SHM_REUSE_ALL_SECOND=true   SHM_REUSE_ANY_VICTIM=false
///   * SECOND HOLDER'S
///     WRITE SUPPRESSED: SHM_REUSE_ALL_SECOND=false  SHM_REUSE_ANY_VICTIM=TRUE
///
/// Total separation, and the injected arm fails on exactly the observable
/// criterion B names: the forgotten holder's bytes surviving into what the new
/// owner reads. No threshold to tune, and one cell red, no other.
///
/// CRITERION B: a chunk reclaimed and re-issued carries only its NEW owner's
/// bytes, and no writer of the old ones survives to interfere.
///
/// ⚠️ WHAT THIS CAN AND CANNOT SHOW, stated because the criterion's wording
/// invites the stronger reading. With the raw pointer gone there is no way for
/// the first holder to write anything after forgetting its buffer — that is a
/// property of the SURFACE, and the cell in `shm_provider_test.dart` that
/// asserts no member returns a `Pointer` is what establishes it. This arm shows
/// the dynamic half: the reclaimed chunk really is re-issued, and the second
/// holder's writes land and read back intact.
Future<void> _reuseAfterReclaimArm() async {
  final provider = ShmProvider(size: shmPoolBytes);

  // Hold the pool down to its last chunk, so the reclaimed one is the ONLY
  // space a later request can be met from. Without this the second holder
  // might be handed a chunk that was never the first holder's, and the arm
  // would pass while measuring nothing.
  final held = <ShmMutBuffer>[];
  while (true) {
    final r = provider.allocGc(shmChunkBytes);
    if (r is! AllocOk) break;
    held.add(r.buffer);
    if (held.length > shmPoolBytes ~/ shmChunkBytes) {
      stdout.writeln('SHM_BAD_ARM=sweep did not terminate');
      exit(2);
    }
  }
  held.removeLast().dispose();
  stdout.writeln('SHM_REUSE_HELD=${held.length}');

  shmAllocPatternAndForget(provider, shmChunkBytes, shmPatternVictim);
  await shmPressureFully();

  final second = provider.allocGc(shmChunkBytes);
  if (second is! AllocOk) {
    stdout.writeln('SHM_REUSE_NOT_REISSUED=1');
    exit(2);
  }
  // The reclaim is what made this succeed: every other chunk is still held.
  stdout.writeln('SHM_REUSE_REISSUED=1');

  second.buffer.write(List<int>.filled(32, shmPatternSecond));
  final read = second.buffer.read(length: 32);
  stdout
    ..writeln(
      'SHM_REUSE_ALL_SECOND='
      '${read.every((b) => b == shmPatternSecond)}',
    )
    ..writeln(
      'SHM_REUSE_ANY_VICTIM=${read.any((b) => b == shmPatternVictim)}',
    );

  second.buffer.dispose();
  for (final b in held) {
    b.dispose();
  }
  provider.close();
  stdout.writeln('SHM_DONE');
}

/// GT-9's declared-unestablished question, and the safety consequence this
/// unit newly creates for it.
///
/// Two things are measured here and they are NOT the same claim:
///
///  * whether an evicted victim and its evictor ALIAS — allocator history,
///    reported and documented, deliberately not asserted;
///  * whether the victim's now-armed finalizer, firing on a chunk the evictor
///    holds, damages the evictor — a MEMORY-SAFETY contract, asserted.
///
/// The second exists because this unit changed the ground under GT-9. When
/// GT-9 was measured, a written buffer sat in the slot-only state and its
/// finalizer never touched the chunk at all, so "dropped cleanly" could not
/// have covered this case. It can now.
Future<void> _evictAliasArm() async {
  final provider = ShmProvider(size: shmPoolBytes);

  final victim = shmExpectOk(provider.alloc(shmEvictionRequest))
    ..write(List<int>.filled(32, shmPatternVictim));
  stdout.writeln('SHM_EVICT_VICTIM_BEFORE=${victim.read(length: 8).first}');

  // Arithmetically forced: two of these do not fit in one pool.
  final evictor = shmExpectOk(provider.allocGcDefragDealloc(shmEvictionRequest))
    ..write(List<int>.filled(32, shmPatternEvictor));
  stdout.writeln('SHM_EVICT_EVICTOR_WROTE=${evictor.read(length: 8).first}');

  // ── the aliasing observation, REPORTED not asserted ──────────────────────
  final victimNow = victim.read(length: 8);
  stdout.writeln(
    'SHM_EVICT_ALIASES=${victimNow.every((b) => b == shmPatternEvictor)}',
  );

  // Can a surviving victim write INTO the live evictor?
  victim.write(List<int>.filled(32, shmPatternSecond));
  stdout.writeln(
    'SHM_EVICT_CORRUPTS='
    '${evictor.read(length: 8).every((b) => b == shmPatternSecond)}',
  );

  // ── the safety half, ASSERTED by the parent ──────────────────────────────
  // Put the evictor back into a known state, then let the victim be collected
  // with its CHUNK-RELEASING net armed — the state this unit created.
  evictor.write(List<int>.filled(32, shmPatternEvictor));
  victim.dispose();
  stdout.writeln('SHM_EVICT_VICTIM_DISPOSED=1');

  await shmPressureFully();
  final survives = evictor.read(length: 8);
  stdout
    ..writeln(
      'SHM_EVICT_EVICTOR_SURVIVES='
      '${survives.every((b) => b == shmPatternEvictor)}',
    )
    ..writeln('SHM_EVICT_EVICTOR_LEN=${evictor.length}');

  evictor.dispose();
  provider.close();
  stdout.writeln('SHM_DONE');
}

/// The same, but the victim is FORGOTTEN rather than released.
///
/// This is the route that only exists because slice 5 re-armed the net: a
/// forgotten written victim now runs `zd_shm_mut_drop` from a finalizer, on a
/// chunk the evictor is using.
Future<void> _evictThenCollectArm() async {
  final provider = ShmProvider(size: shmPoolBytes);
  shmAllocPatternAndForget(
    provider,
    shmEvictionRequest,
    shmPatternVictim,
  );

  final evictor = shmExpectOk(provider.allocGcDefragDealloc(shmEvictionRequest))
    ..write(List<int>.filled(32, shmPatternEvictor));

  await shmPressureFully();

  final read = evictor.read(length: 8);
  stdout
    ..writeln(
      'SHM_COLLECT_EVICTOR_SURVIVES='
      '${read.every((b) => b == shmPatternEvictor)}',
    )
    ..writeln('SHM_COLLECT_EVICTOR_LEN=${evictor.length}');

  evictor.dispose();
  provider.close();
  stdout.writeln('SHM_DONE');
}

/// Slice 11 — the never-satisfiable arm, in a child, for the reason the whole
/// unit turns on.
///
/// ⛔ A request the pool can never satisfy is ACCEPTED by canon and then never
/// answered: no result, no error, and no context release either. Closing the
/// provider ends the DART wait and cannot cancel canon's request, so the
/// segment is retained for the life of the process.
///
/// ▶ In a child, that life is the cell's. Run in the suite process it would
/// add a permanent locked-bytes contribution to the very budget a later slice
/// has to account for, and it would do to the suite exactly what this unit's
/// own dartdoc tells users not to do to their programs.
Future<void> _asyncCloseArm() async {
  final provider = ShmProvider(size: shmPoolBytes);
  // Four times the pool: unambiguous about the class. ⚠️ Even the NOMINAL
  // pool size never completes -- the pool carries its own overhead -- so
  // "the pool size" would be in this class too, and less obviously.
  final pending = provider.allocGcDefragAsync(shmPoolBytes * 4);
  stdout.writeln('SHM_ASYNC_STARTED');

  // It must still be pending after a bounded interval. `timeout` here bounds
  // the CHECK, not the request: a completion inside the window is the
  // finding, and it is reported rather than waited out.
  var settledEarly = false;
  await pending
      .timeout(
        const Duration(milliseconds: 400),
        onTimeout: () => throw TimeoutException('still pending, as expected'),
      )
      .then<void>((_) => settledEarly = true)
      .catchError((Object e) {
        if (e is! TimeoutException) settledEarly = true;
      });
  stdout.writeln('SHM_ASYNC_SETTLED_EARLY=$settledEarly');

  // ⛔ The second request is REFUSED while the first is in flight.
  var refused = false;
  try {
    await provider.allocGcDefragAsync(shmChunkBytes);
  } on Object catch (e) {
    // ⚠️ Caught as Object and DISCRIMINATED here rather than with `on
    // StateError`: the lint rightly objects to catching an Error, and the
    // claim under test is precisely that the refusal is a StateError -- a
    // programming-error signal -- rather than an exception a caller should
    // handle. Reporting the type is what lets the parent assert it.
    refused = e is StateError;
  }
  stdout.writeln('SHM_ASYNC_SECOND_REFUSED=$refused');

  // Closing ANSWERS the outstanding request rather than abandoning it.
  var completedOnClose = false;
  var threwOnClose = false;
  final answered = pending.then<void>(
    (_) => completedOnClose = true,
    onError: (Object _) => completedOnClose = true,
  );
  try {
    provider.close();
  } on Object {
    threwOnClose = true;
  }
  await answered.timeout(
    const Duration(seconds: 5),
    onTimeout: () => stdout.writeln('SHM_ASYNC_CLOSE_DID_NOT_ANSWER'),
  );
  stdout
    ..writeln('SHM_ASYNC_CLOSE_THREW=$threwOnClose')
    ..writeln('SHM_ASYNC_ANSWERED_ON_CLOSE=$completedOnClose');

  // And closing again is still a no-op.
  var secondCloseThrew = false;
  try {
    provider.close();
  } on Object {
    secondCloseThrew = true;
  }
  stdout.writeln('SHM_ASYNC_SECOND_CLOSE_THREW=$secondCloseThrew');

  // A request started after close is refused, not queued.
  var afterCloseRefused = false;
  try {
    await provider.allocGcDefragAsync(shmChunkBytes);
  } on Object catch (e) {
    afterCloseRefused = e is StateError;
  }
  stdout
    ..writeln('SHM_ASYNC_AFTER_CLOSE_REFUSED=$afterCloseRefused')
    ..writeln('SHM_DONE');
}

/// The slot is released when a request COMPLETES, so the refusal is transient.
///
/// ⛔ Runs in the suite process deliberately: it strands nothing. Every request
/// here is satisfiable and every buffer is released.
Future<void> _asyncSlotReleaseArm() async {
  final provider = ShmProvider(size: shmPoolBytes);
  final first = await provider.allocGcDefragAsync(shmChunkBytes);
  var firstOk = false;
  if (first is AllocOk) {
    firstOk = true;
    first.buffer.dispose();
  }
  // The lane must reopen the moment the first request is answered.
  final second = await provider.allocGcDefragAsync(shmChunkBytes);
  var secondOk = false;
  if (second is AllocOk) {
    secondOk = true;
    second.buffer.dispose();
  }
  stdout
    ..writeln('SHM_SLOT_FIRST_OK=$firstOk')
    ..writeln('SHM_SLOT_SECOND_OK=$secondOk');
  provider.close();
  stdout.writeln('SHM_DONE');
}

/// Slice 12 — the deferred drop, on the path canon DOES complete.
///
/// A provider closed while a SATISFIABLE request is in flight must have its
/// segment reclaimed once that request lands. Deferral is a delay, not an
/// abandonment.
Future<void> _deferredDropArm() async {
  shmWarmUpTheLazyLock();
  final baseline = _lockedOrExit();
  stdout.writeln('SHM_DEFER_BASELINE=$baseline');

  final provider = ShmProvider(size: shmPoolBytes);
  final pending = provider.allocGcDefragAsync(shmChunkBytes);
  // Close IMMEDIATELY, while the request is still outstanding. Before this
  // unit that was a segfault; now the slot is handed to the shim.
  provider.close();
  stdout.writeln('SHM_DEFER_CLOSED');

  // The Future is answered either way -- by the result, or by close().
  //
  // ⛔ THE BUFFER MUST BE RELEASED, and the first cut of this arm did not:
  // a live chunk pins its segment, so the reading came back +65536 and looked
  // exactly like a failed deferral. The arm's subject is the PROVIDER's
  // reclamation, so anything else holding the segment has to be let go first
  // or the measurement is about the wrong thing.
  await pending.then<void>(
    (r) {
      if (r is AllocOk) r.buffer.dispose();
    },
    onError: (Object _) {},
  );
  stdout.writeln('SHM_DEFER_ANSWERED');

  // ⚠️ CONVERGENCE, NOT A FIXED WAIT. Canon releases its reference from its
  // own thread at a time nothing here controls, so the reading is polled to a
  // DEADLINE and the cell fails with the last value it saw rather than on a
  // guess about how long is long enough.
  var after = _lockedOrExit();
  for (var round = 1; round <= 40 && after != baseline; round++) {
    await shmPressureRound(round);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    after = _lockedOrExit();
  }
  stdout
    ..writeln('SHM_DEFER_AFTER=$after')
    ..writeln('SHM_DEFER_DELTA=${after - baseline}')
    ..writeln('SHM_DONE');
}

/// Slice 12 — a provider with NO pending request closes immediately.
///
/// The control that shows the deferral costs nothing where it is not needed:
/// the same measurement, the same pool, no async request ever started.
Future<void> _immediateDropArm() async {
  shmWarmUpTheLazyLock();
  final baseline = _lockedOrExit();
  stdout.writeln('SHM_IMMEDIATE_BASELINE=$baseline');
  final provider = ShmProvider(size: shmPoolBytes);
  final live = _lockedOrExit();
  provider.close();
  final after = _lockedOrExit();
  stdout
    ..writeln('SHM_IMMEDIATE_WHILE_LIVE_DELTA=${live - baseline}')
    ..writeln('SHM_IMMEDIATE_DELTA=${after - baseline}')
    ..writeln('SHM_DONE');
}

/// Slice 12 — COLLECTION cannot reach the crashing drop either.
///
/// ⛔ THE ORDER OF WHAT THIS PRINTS IS THE WHOLE POINT. "The child exited
/// normally" passes whether or not the finalizer ever ran, so on its own it is
/// an assertion placed where it succeeds either way. If the pending request's
/// bookkeeping kept the wrapper reachable, NOTHING would fire and a clean exit
/// would read as a pass while exercising none of the deferred path.
///
/// So the arm reports the finalizer COUNT, and the parent requires it to have
/// moved. That is not hypothetical: `finalizer_harness.dart:455-459` records an
/// earlier cut where an object stayed reachable, the arm reported 0, and it
/// would have read as "the transition never happened".
/// ⛔⛔ THE POOL MUST BE EXHAUSTED, AND THE FIRST CUT OF THIS ARM GOT IT WRONG.
///
/// The crashing state is one where canon has a LIVE WAITER: an exhausted pool
/// with a request it could meet if space freed. A request four times the pool
/// is parked with no waiter at all, and dropping under it is harmless -- that
/// version of this arm passed **5/5 while exercising a state that cannot
/// crash**, which is a green that proves nothing.
///
/// Measured, the correct shape, dropping through the FINALIZER:
///   before this slice's net swap:  SIGSEGV, 3/3
///   after:                         FIN_FIRED=1 and SURVIVED, 5/5
@pragma('vm:never-inline')
void _startAndForgetProvider() {
  final provider = ShmProvider(size: shmPoolBytes);
  final held = <ShmMutBuffer>[];
  while (true) {
    final r = provider.allocGc(shmChunkBytes);
    if (r is! AllocOk) break;
    held.add(r.buffer);
  }
  stdout.writeln('SHM_COLLECT_HELD=${held.length}');
  // Outstanding when the only reference to the provider dies with this frame.
  unawaited(
    provider
        .allocGcDefragAsync(shmChunkBytes)
        .then<void>((_) {}, onError: (Object _) {}),
  );
}

Future<void> _collectWithPendingArm() async {
  final before = bindings.zd_fin_invocations(
    ZdFinKind.shmProviderDeferred,
  );
  stdout.writeln('SHM_COLLECT_FIN_BEFORE=$before');
  _startAndForgetProvider();
  await shmPressureFully();
  final after = bindings.zd_fin_invocations(ZdFinKind.shmProviderDeferred);
  stdout
    ..writeln('SHM_COLLECT_FIN_AFTER=$after')
    ..writeln('SHM_COLLECT_FIN_FIRED=${after - before}')
    ..writeln('SHM_DONE');
  // ⛔ EXPLICIT EXIT, and it is this unit's own documented behaviour rather
  // than a workaround. The forgotten provider's request can never be answered
  // and nothing closed it, so its port is still open and holds the isolate --
  // exactly what `allocGcDefragAsync`'s dartdoc warns about. The arm has
  // already measured everything it came for; waiting would only prove the
  // hang, which is not this arm's subject.
  await stdout.flush();
  exit(0);
}

/// Runs one named arm. The parent picks it; there is no default.
Future<void> main(List<String> args) async {
  if (!ZenohFeatures.hasSharedMemory) {
    stdout.writeln('SHM_UNAVAILABLE=this native ships no shared memory');
    exit(3);
  }
  stdout.writeln('SHM_READY');
  final arm = args.isEmpty ? '' : args.first;
  switch (arm) {
    case 'chunk-forget':
      await _chunkForgetArm();
    case 'provider-forget':
      await _providerForgetArm();
    case 'reuse-after-reclaim':
      await _reuseAfterReclaimArm();
    case 'evict-alias':
      await _evictAliasArm();
    case 'evict-then-collect':
      await _evictThenCollectArm();
    case 'async-close':
      await _asyncCloseArm();
    case 'async-slot-release':
      await _asyncSlotReleaseArm();
    case 'deferred-drop':
      await _deferredDropArm();
    case 'immediate-drop':
      await _immediateDropArm();
    case 'collect-with-pending':
      await _collectWithPendingArm();
    default:
      stdout.writeln('SHM_BAD_ARM=$arm');
      exit(2);
  }
}
