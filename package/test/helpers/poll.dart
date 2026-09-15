import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

/// How long the pollers below wait before failing.
const _defaultTimeout = Duration(seconds: 5);

/// Polls until [condition] holds, then returns; fails if [timeout] passes.
///
/// For the "wait until X has happened" class of wait — delivery, propagation,
/// a link coming up. A fixed `Future.delayed` there asserts the machine's
/// speed rather than the condition, and goes red under load for reasons that
/// have nothing to do with the code under test.
///
/// Not for settle time ("let things quiesce before the next step"), which has
/// no condition to poll and should stay a sleep.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = _defaultTimeout,
  String description = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out after ${timeout.inSeconds}s waiting for $description.');
}

/// Polls [PullSubscriber.tryRecv] until a sample arrives, or [timeout] passes.
///
/// Returns null on timeout so callers keep their own `isNotNull` assertion --
/// the failure then names the sample the test was actually about.
///
/// The PUBLIC SHAPE is deliberately unchanged by seed #5's retype. `tryRecv`
/// now returns a three-way `RecvResult`, but this helper's contract is "the
/// one sample I was waiting for, or nothing" -- a genuine binary, so a
/// nullable is the conforming rendering here (convention S1: a nullable
/// survives where the result really is binary). Keeping the shape is what
/// leaves its twelve consumer sites untouched.
///
/// It does switch on the discriminant internally, and gains one behaviour it
/// could not have before: on `RecvDisconnected` it returns IMMEDIATELY rather
/// than burning the full timeout. A dead channel will never produce the
/// sample, so waiting five more seconds only delays the caller's own
/// `isNotNull` failure -- and that failure now arrives with the channel still
/// visibly dead, which is the more useful diagnosis.
///
/// `tryRecv` is synchronous and leaves the buffer untouched when empty, so it
/// is its own readiness probe. This matters more here than on the stream
/// paths: those self-poll through `first.timeout(...)`, but a single
/// `tryRecv` behind a fixed sleep gives a late sample no second chance.
///
/// Use this only where exactly one sample is expected. Where a burst is
/// published and the test then drains the channel, waiting is *settle* time
/// for the burst -- polling for the first arrival could drain mid-burst and
/// read the wrong samples.
Future<Sample?> pollRecv(
  PullSubscriber sub, {
  Duration timeout = _defaultTimeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    switch (sub.tryRecv()) {
      case RecvData(:final value):
        return value;
      case RecvDisconnected():
        // Terminal: nothing will ever arrive. Fail fast rather than sleeping
        // out the timeout.
        return null;
      case RecvEmpty():
        // Alive, nothing buffered yet -- back off and look again.
        break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return null;
}

/// Polls a channel's `tryRecv` until it reports something other than
/// [RecvEmpty], or [timeout] passes — in which case the final [RecvEmpty] is
/// returned rather than thrown, so the caller's own assertion names the thing
/// the test was about.
///
/// Unlike [pollRecv] this PRESERVES THE DISCRIMINANT. `pollRecv` answers "the
/// one sample I was waiting for, or nothing", which is a genuine binary; the
/// channel cells in seed #6 have to tell `RecvDisconnected` apart from "still
/// nothing yet", because on a reply channel those two are the whole contract.
///
/// Generic over the payload, so one poller serves the reply, query and sample
/// columns instead of three that drift apart.
Future<RecvResult<T>> pollUntilNotEmpty<T>(
  RecvResult<T> Function() tryRecv, {
  Duration timeout = _defaultTimeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  var last = tryRecv();
  while (last is RecvEmpty<T> && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    last = tryRecv();
  }
  return last;
}

/// Drains a channel to its terminal state, returning everything it handed over.
///
/// Stops at [RecvDisconnected]; an [RecvEmpty] that persists past [timeout]
/// also stops the drain, so a channel that never terminates fails the caller's
/// assertion rather than hanging the suite.
Future<List<T>> drainToTerminal<T>(
  RecvResult<T> Function() tryRecv, {
  Duration timeout = _defaultTimeout,
}) async {
  final drained = <T>[];
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    switch (tryRecv()) {
      case RecvData(:final value):
        drained.add(value);
      case RecvDisconnected():
        return drained;
      case RecvEmpty():
        await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  return drained;
}
