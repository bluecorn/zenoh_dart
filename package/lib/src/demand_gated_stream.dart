import 'dart:async';

import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/recv_result.dart';

/// A demand-gated [Stream] view over a bounded pull channel.
///
/// The shared mechanism behind `PullSubscriber.stream` and
/// `PullQueryable.stream`. It is deliberately **not exported**: two
/// implementations justify one shared class, and neither of them is an
/// abstraction over a single implementation.
///
/// ## What "demand-gated" means here
///
/// The gate holds no buffer of its own. It runs a loop that takes ONE value at
/// a time out of the channel through `pull` — the handle's own shipped
/// `recv()` — and only while the subscription is actually demanding: a
/// listener attached, not paused, not cancelled, the gate open. Pause the
/// subscription and the loop stops pulling, so what accumulates is the native
/// channel's own `capacity` and nothing else grows. That is the whole point:
/// the push `Stream` this package shipped first buffers into an unbounded
/// `StreamController` seam, which is a bound in name only.
///
/// ## The pinned in-flight semantics — and why `capacity + 1`
///
/// **The first pull starts synchronously inside `onListen`.** The drive loop's
/// body runs to its first `await`, so `pull` has already been invoked by the
/// time control returns to the caller of `listen()`. A synchronous
/// `listen(); pause();` therefore leaves exactly **one pull in flight**, and
/// the value that completes it lands in a one-slot **stash**.
///
/// The alternative — deferring the first pull to a later microtask — does not
/// remove the stash. A pause that lands while a pull is in flight stashes under
/// either rule; deferral only changes the initial condition, which makes the
/// retained amount `capacity` *or* `capacity + 1` depending on how the pause
/// was reached. That is a state the consumer can neither see nor control.
/// Pinning the pull to `onListen` makes the retained bound **single-valued**:
/// **at most `capacity + 1`**, rather than a bound that depends on how the
/// pause was reached.
///
/// ⚠️ **`capacity + 1` is a CEILING, not an equality**, and the difference is
/// measured rather than assumed. Swept on the QUERY column, `ring,
/// capacity: 8`, one getter per arrival: 9 arrivals retain 9 — the ceiling
/// exactly — while 20 and 64 retain **8**, because canon's ring makes room
/// *before* it inserts and concurrent producers leave it one short. On the
/// SAMPLE column, where arrivals come serially down one link, 1024 arrivals
/// retained 9. So the shortfall is a property of the arrival pattern, not of
/// the gate — which is why the claim here is "at most" and both 8 and 9
/// satisfy it.
///
/// **On resume the stashed value is emitted BEFORE the next pull is issued**,
/// so the delivery order is the arrival order.
///
/// ## The stash is never dropped on the floor
///
/// A value that completes a pull into a paused or cancelled gate is stashed,
/// not released, and it has exactly two exits:
///
/// - **Retrieved through the handle** — the owning handle's `tryRecv()` calls
///   [takeStash] *first*, which preserves the ordering `recv()`'s own dartdoc
///   already publishes: an interleaved `tryRecv` "is fine and *wins*".
/// - **Released at [close]** — whatever is still stashed is handed to
///   `release`, which is `Query.dispose` on the query column and a no-op on the
///   sample column.
///
/// There is one case where a value is released rather than stashed: the
/// controller is already closed, so nothing could ever retrieve it.
class DemandGate<T extends Object> {
  /// Creates a gate that takes values through [pull] and hands unretrievable
  /// ones to [release].
  ///
  /// [pull] is the owning handle's `recv()`. [release] is what disposes a
  /// value the consumer will never see — `Query.dispose` on the query column,
  /// a no-op where the value holds no native resource.
  DemandGate({
    required Future<RecvResult<T>> Function() pull,
    required void Function(T value) release,
  })
    // A named parameter cannot be written `this._pull`: named parameters
    // may not start with an underscore, so an initializing formal is not
    // expressible for a private field here.
    // ignore: prefer_initializing_formals
    : _pull = pull,
       // Same reason as the field above.
       // ignore: prefer_initializing_formals
       _release = release {
    // All four gate callbacks are wired -- the four this package had ZERO of,
    // which is exactly why its push `Stream`'s `pause()` was inert.
    //
    // `onListen` and `onResume` DRIVE. `onPause` and `onCancel` carry no body
    // on purpose, and the reason is measured rather than stylistic: the loop
    // tests demand by reading the controller's OWN state, which is true the
    // instant `pause()` or `cancel()` is called -- including from inside
    // `onData`, where the callback itself does not fire until the callback
    // returns. Caching that state in a flag set from these two handlers would
    // leave a window in which the loop still believed it had demand and
    // delivered into a paused subscription instead of stashing.
    _controller = StreamController<T>(
      onListen: _onDemand,
      onPause: _stateIsReadNotCached,
      onResume: _onDemand,
      onCancel: _stateIsReadNotCached,
    );
  }

  /// See the constructor: the gate reads `isPaused`/`hasListener` directly, so
  /// these two handlers have nothing to record.
  static void _stateIsReadNotCached() {}

  final Future<RecvResult<T>> Function() _pull;
  final void Function(T value) _release;

  late final StreamController<T> _controller;

  /// The one-slot stash. Non-null exactly when [hasStash] is true.
  T? _stash;

  /// True while the drive loop is running, so a second `onResume` cannot start
  /// a competing loop.
  bool _running = false;

  bool _closed = false;
  bool _inFlight = false;

  /// The demand-gated stream. Single-subscription, exactly like the two
  /// accessors it sits beside.
  Stream<T> get stream => _controller.stream;

  /// Whether a pull is outstanding right now. **Test instrument only.**
  ///
  /// Surfaced through the owning handle as `pullInFlightForTesting`. A cell
  /// that infers the drive loop's state from a recipe rather than asserting it
  /// is how four mis-specified cells got written; this is what lets a cell
  /// assert instead.
  bool get inFlight => _inFlight;

  /// Whether a value is sitting in the one-slot stash. **Test instrument
  /// only.** See [inFlight].
  bool get hasStash => _stash != null;

  /// Takes the stashed value, or null when there is none.
  ///
  /// The owning handle's `tryRecv()` calls this **before** touching the native
  /// channel, which is the first of the stash's two exits.
  T? takeStash() {
    final value = _stash;
    _stash = null;
    return value;
  }

  /// Closes the gate: releases anything still stashed, then closes the
  /// controller. Idempotent.
  ///
  /// The owning handle calls this from its own `close()`, *after* completing a
  /// pending `recv()` waiter and *before* any native drop — everything
  /// Dart-side that could re-enter canon is quiesced first.
  void close() {
    if (_closed) return;
    _closed = true;
    final stashed = takeStash();
    if (stashed != null) _release(stashed);
    if (!_controller.isClosed) unawaited(_controller.close());
  }

  /// True while the subscription is asking for values.
  ///
  /// `hasListener` is checked first deliberately: `isPaused` is not meaningful
  /// without a listener.
  bool get _demanded =>
      !_closed &&
      _controller.hasListener &&
      !_controller.isPaused &&
      !_controller.isClosed;

  void _onDemand() {
    unawaited(_drive());
  }

  /// The drive loop. At most one pull in flight, ever.
  Future<void> _drive() async {
    // Runs synchronously, before the first `await` below: this is what makes
    // `onListen` start its pull inside `listen()`.
    if (_running) return;
    _running = true;
    try {
      while (_demanded) {
        // The stash is emitted BEFORE the next pull is issued, so a resumed
        // subscription sees arrival order rather than the stash last.
        final stashed = takeStash();
        if (stashed != null) {
          _controller.add(stashed);
          continue;
        }

        RecvResult<T> result;
        _inFlight = true;
        try {
          // ⚠️ THE CALL SITS INSIDE THE `try`, not merely awaited. `recv()`
          // throws SYNCHRONOUSLY on a closed or contended handle, and an
          // `async` body whose returned future is ignored would leak that
          // throw to the zone instead of the stream.
          result = await _pull();
        } on ZenohException catch (error, stackTrace) {
          // Canon calls this a call failure, not a channel state: the channel
          // is alive, so the error is forwarded and the loop CONTINUES.
          // Terminal states live in the result type, not the error channel.
          _inFlight = false;
          if (!_controller.isClosed) _controller.addError(error, stackTrace);
          continue;
          // `recv()` reports a closed or contended handle as a StateError, so
          // this arm renders a shipped throw contract rather than swallowing
          // an error.
          // ignore: avoid_catching_errors
        } on StateError catch (error, stackTrace) {
          // The handle is closed or contended — there is nothing left to pull.
          _inFlight = false;
          if (!_controller.isClosed) {
            _controller
              ..addError(error, stackTrace)
              ..close().ignore();
          }
          return;
        }
        _inFlight = false;

        // Exhaustive over the sealed family, no `default` arm.
        switch (result) {
          case RecvData(:final value):
            if (_controller.isClosed) {
              // Nothing can retrieve it, so this is the one case that
              // releases rather than stashes.
              _release(value);
              return;
            }
            if (!_demanded) {
              // Paused or cancelled: the value is STASHED, never dropped.
              _stash = value;
              return;
            }
            _controller.add(value);
          case RecvEmpty():
            // Contractually unreachable from `recv()`, which waits rather than
            // reporting an empty buffer. Normalised rather than assumed away.
            continue;
          case RecvDisconnected():
            // Reached only when the SESSION closes first with the handle still
            // open; every handle-close path closes this gate first.
            if (!_controller.isClosed) _controller.close().ignore();
            return;
        }
      }
    } finally {
      _running = false;
    }
  }
}
