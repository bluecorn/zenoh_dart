import 'package:meta/meta.dart';

import 'package:zenoh_dart/src/unstable/features.dart';

/// Controls the behavior when the outgoing buffer is full.
///
/// ## The default is not uniform — it depends on the operation
///
/// canon picks a different default for *push* operations than for *request*
/// operations, so omitting [CongestionControl] does not mean the same thing
/// everywhere:
///
/// | operation | canon default |
/// |---|---|
/// | `put`, `putBytes`, `deleteResource`, `declarePublisher` | [drop] |
/// | `get`, `declareQuerier` | [block] |
///
/// Every binding method that takes a congestion control names its own default
/// in its own documentation. Do not assume uniformity: the same omission means
/// "lose the message rather than wait" on a publication and "wait rather than
/// lose it" on a query.
///
/// ## ⚠️ Choosing [drop] does not protect you from someone else's [block]
///
/// All messages at the same priority share one network pipeline. A
/// *different* message — possibly from another part of your program, or
/// another entity on the same session — that chose [block] can stall it for
/// up to that message's full `wait_before_close` budget, and yours waits behind
/// it regardless of what you chose. Selecting [drop] for a latency-sensitive
/// stream bounds how long *your* message waits to be enqueued; it does not
/// bound how long the pipeline is blocked by someone else.
///
/// This is upstream zenoh behavior, tracked as an open bug (zenoh core #2584),
/// and has been observed in the field with a publisher and a queryable sharing
/// one session.
enum CongestionControl {
  /// Wait for buffer space, and take the transport down if it never comes.
  ///
  /// When the transport is congested the send **parks the calling thread** for
  /// up to `wait_before_close`. If that budget expires the message is **lost
  /// anyway** *and* the whole transport is closed as unresponsive — every other
  /// entity on it is affected, not just this message.
  ///
  /// So [block] is not "reliable delivery". It trades a bounded loss for an
  /// unbounded stall followed by a possible transport teardown. Prefer it only
  /// where losing a message is worse than pausing the caller, and where you
  /// have accounted for the teardown.
  ///
  /// `wait_before_close` defaults to **5 seconds** in the pinned zenoh-c
  /// 1.8.0. That figure is a *configuration default*, not a constant — it is
  /// overridable through the session config, so read it from your own
  /// configuration rather than relying on this number.
  ///
  /// canon's default for `get` and `declareQuerier` (`DEFAULT_REQUEST`).
  block(0),

  /// Drop the message rather than wait for buffer space.
  ///
  /// The send parks for at most `wait_before_drop` and then discards the
  /// message. Nothing is torn down and the caller is not held up.
  ///
  /// `wait_before_drop` defaults to **1 millisecond** in the pinned zenoh-c
  /// 1.8.0 — again a configuration default, overridable, not a constant.
  ///
  /// See the class documentation: choosing [drop] bounds your own wait, but a
  /// concurrent [block] message at the same priority can still stall you.
  ///
  /// canon's default for `put`, `putBytes`, `deleteResource` and
  /// `declarePublisher` (`DEFAULT_PUSH`).
  drop(1),

  /// Block the publisher until the first message is sent, then behave like
  /// [drop] for subsequent messages while the buffer stays full.
  ///
  /// Unstable / zenoh-c-only: this maps to `Z_CONGESTION_CONTROL_BLOCK_FIRST`
  /// (wire value 2), which is only available when zenoh-c is compiled with
  /// `Z_FEATURE_UNSTABLE_API`.
  ///
  /// ⛔ **Against a `stable` native this value is REFUSED**, with an
  /// [ArgumentError] naming the argument, raised before anything is
  /// allocated, consumed or declared. This package ships both a `stable` and
  /// an `unstable` native, and the door you import does not select which one
  /// you get — your app's `user_defines` does.
  ///
  /// ⚠️ **What the refusal prevents is undefined behaviour, not a
  /// substitution.** Without `Z_FEATURE_UNSTABLE_API` canon's
  /// `z_congestion_control_t` carries two variants, so passing this value on
  /// would hand it a discriminant outside its own `#[repr(C)]` enum. On one
  /// measured build that resolved to [block] with nothing thrown and nothing
  /// logged — but that is one build's resolution of undefined behaviour, not
  /// a contract, and it is not the QoS you asked for either way.
  ///
  /// Two remedies, either one enough: pass [block] or [drop], which every
  /// build carries; or select the unstable native in your **app's**
  /// `pubspec.yaml`, under
  /// `hooks: user_defines: zenoh_dart: variant: unstable`.
  blockFirst(2);

  const CongestionControl(this.value);

  /// The zenoh-c wire value. Explicit; never derived from declaration order.
  final int value;

  /// Decodes a zenoh-c wire congestion-control value (0/1/2) into a
  /// [CongestionControl].
  ///
  /// Wire value 2 is the unstable `Z_CONGESTION_CONTROL_BLOCK_FIRST` and
  /// decodes to [CongestionControl.blockFirst]. Only genuinely out-of-range
  /// values (`raw < 0` or `raw >= values.length`) fall back to
  /// [CongestionControl.block] rather than crashing on an unbounded index.
  static CongestionControl fromWire(int raw) {
    if (raw < 0 || raw >= CongestionControl.values.length) {
      return CongestionControl.block;
    }
    return CongestionControl.values[raw];
  }
}

/// Refuses [CongestionControl.blockFirst] on a native that cannot represent
/// it.
///
/// ⛔ **This is not the unstable-door gate.** `requireUnstable()` answers a
/// different question — *"you imported `zenoh_unstable` and loaded a stable
/// native"* — and says so in its message, which is the wrong sentence for a
/// caller who never imported that door. [CongestionControl.blockFirst] is a
/// **stable-door** member: the door a consumer imports and the native their
/// pubspec selects are orthogonal axes, and this is the one member where the
/// second axis decides whether a value is representable at all.
///
/// ⛔ **What it prevents is undefined behaviour, not a substitution.** canon
/// declares `Z_CONGESTION_CONTROL_BLOCK_FIRST` only under
/// `Z_FEATURE_UNSTABLE_API`; without that flag `z_congestion_control_t` is a
/// two-variant `#[repr(C)]` enum, and the shim's lower-bound-only check casts
/// a `2` straight into it. Measured on one host the value resolves to
/// [CongestionControl.block] with nothing thrown and nothing logged — but
/// that is one build's resolution of undefined behaviour, not a contract.
///
/// Called as the **first statement** of every entry point that accepts a
/// [CongestionControl], so a refused call allocates nothing, consumes
/// nothing, declares nothing and opens no port.
@internal
void requireCongestionControlSupported(CongestionControl? value) {
  // SHORT-CIRCUIT BEFORE THE FEATURE BITS ARE CONSULTED. Reading
  // ZenohFeatures loads the native; the two decode-seam test files touch only
  // `.value` and `fromWire` and must stay native-free, so the cheap
  // comparison comes first and the predicate is evaluated only for the one
  // value that can be refused.
  if (value != CongestionControl.blockFirst) return;
  if (ZenohFeatures.hasUnstableApi) return;
  throw ArgumentError.value(
    CongestionControl.blockFirst,
    'congestionControl',
    'is Z_CONGESTION_CONTROL_BLOCK_FIRST (wire value 2), which zenoh-c '
        'declares only under Z_FEATURE_UNSTABLE_API — and the loaded '
        'libzenoh_dart.so was built without it. Passing it on would hand '
        'canon a discriminant outside its enum: undefined behaviour, not a '
        'substitution.\n\n'
        'Two remedies, and either one is enough:\n'
        '  * pass CongestionControl.block or CongestionControl.drop, which '
        'every build carries; or\n'
        "  * select the unstable native in your APP's pubspec.yaml (the root "
        'package — a dependency cannot set this):\n'
        '      hooks:\n'
        '        user_defines:\n'
        '          zenoh_dart:\n'
        '            variant: unstable',
  );
}
