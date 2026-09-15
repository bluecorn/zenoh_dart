import 'dart:async';

import 'package:meta/meta.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/reply.dart';

/// Delivered-tracking for retained payloads on a **reply** channel.
///
/// Seed `[10a]` slice 9. The carrier rule: something that hands a caller an
/// object backed by native memory must track what it has **delivered**,
/// because only the *undelivered* ones have no other owner.
///
/// ## Why this is a shared helper while the two reply PARSES are not
///
/// `Session.get` and `Querier.get` parse replies in separate code, and that
/// separation is deliberate — a fix applied to only one of them once left
/// every `Querier` reply truncating, so each carries its own failing leg and
/// factoring the parses together would hide exactly that divergence.
///
/// **The release is a different matter.** What it means to release a retained
/// reply payload is one thing, not two, and duplicating it is how an omission
/// gets in. So the parses stay apart and the bookkeeping is shared.
///
/// ## The filter is armed by the flag
///
/// With retention off no handle exists and nothing is ever tracked, so an
/// unconditional `where(...)` filter would suppress **every** reply and the
/// consumer would receive nothing. Retention-off carriers therefore pay
/// nothing here: no set, no filter, no per-reply work.
@internal
class ReplyRetention {
  /// Creates a tracker for a carrier that retains when [enabled] is true.
  ReplyRetention({required this.enabled});

  /// How many retained reply handles are tracked-but-not-yet-delivered across
  /// every live reply carrier in this isolate.
  ///
  /// ⛔ THIS EXISTS BECAUSE THE FINALIZER COUNTER IS STRUCTURALLY BLIND TO THE
  /// DEFECT IT WOULD OTHERWISE BE ASKED TO CATCH. `zd_fin_invocations`
  /// separates "an enumerated path released it" from "the net reclaimed it" —
  /// but the net only ever fires on an object that has become UNREACHABLE. A
  /// carrier that fails to drain does not produce garbage; it keeps every
  /// handle strongly reachable from [_undelivered] forever, so the net never
  /// runs and the counter reads a clean zero on a permanently leaking tree.
  ///
  /// Measured: deleting the drain call reddened nothing at all until this
  /// counter existed. **A leak into a live set is invisible to a
  /// reclamation-based instrument, by construction.**
  static int liveUndelivered = 0;

  /// Whether this carrier asked the shim for retained payload handles.
  final bool enabled;

  final Set<ZBytes> _undelivered = Set<ZBytes>.identity();

  /// The retained handle a reply carries, or null.
  ///
  /// ⛔ Only the **ok** arm can carry one: the error-reply payload is a carve
  /// homed to the terminal unit, so `ReplyError` never has a handle to track.
  static ZBytes? handleOf(Reply reply) =>
      reply.isOk ? reply.ok.payloadZBytes : null;

  /// Records a parsed reply as arrived-but-not-yet-delivered.
  void track(Reply reply) {
    if (!enabled) return;
    final retained = handleOf(reply);
    if (retained != null && _undelivered.add(retained)) {
      liveUndelivered++;
    }
  }

  /// Releases a reply that can never reach a consumer.
  ///
  /// Called from the listener's already-closed branch: the controller has shut
  /// and this message was still in the port queue, so nobody can receive it.
  void dropUndeliverable(Reply reply) {
    handleOf(reply)?.dispose();
  }

  /// Wraps [source] so that passing through it counts as delivery.
  Stream<Reply> gate(Stream<Reply> source) =>
      enabled ? source.where(_markDelivered) : source;

  bool _markDelivered(Reply reply) {
    final retained = handleOf(reply);
    // A reply with no handle has nothing to track and is never suppressed —
    // an error reply, or an ok reply from a retention-off carrier.
    if (retained == null) return true;
    // False means [drain] already released it, so it must not be handed over
    // carrying an already-disposed handle.
    final wasTracked = _undelivered.remove(retained);
    if (wasTracked) liveUndelivered--;
    return wasTracked;
  }

  /// Releases every retained handle that arrived but was never delivered.
  ///
  /// A reply channel **self-terminates at query completion**, unlike a
  /// subscriber that lives until closed — so this runs on that terminal path
  /// as well as on an explicit close.
  void drain() {
    for (final retained in _undelivered) {
      retained.dispose();
      liveUndelivered--;
    }
    _undelivered.clear();
  }
}
