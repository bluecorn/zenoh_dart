/// The result of consuming one value from a bounded zenoh channel.
///
/// Canon's channel handlers report **three** distinct outcomes through their
/// return code, not two: `Z_OK` (a value was taken), `Z_CHANNEL_NODATA` and
/// `Z_CHANNEL_DISCONNECTED`. They are the only positive result codes in the
/// whole zenoh-c API, deliberately outside the negative error space, because
/// they are *states a consumer switches on* rather than failures.
///
/// This sealed family preserves every distinction canon draws. Switch over it
/// exhaustively and write no `default` arm:
///
/// ```dart
/// switch (pull.tryRecv()) {
///   case RecvData(:final value):
///     print(value.payload);
///   case RecvEmpty():
///     // nothing buffered right now -- back off and poll again
///   case RecvDisconnected():
///     // the producer is gone; stop polling
/// }
/// ```
///
/// A *call* failure -- an allocation that could not be satisfied, a canon
/// error code -- is not a member of this family. Those throw
/// `ZenohException`, exactly as everywhere else in the binding, so no switch
/// site has to handle conditions canon itself calls faults.
///
/// The type is generic because more than one receive surface shares it:
/// samples from a `PullSubscriber`, and query replies.
library;

/// The outcome of a single `tryRecv`/`recv` on a bounded channel of [T].
///
/// Sealed: [RecvData], [RecvEmpty] and [RecvDisconnected] are the only
/// members, so a `switch` over the three is exhaustive without a `default`.
sealed class RecvResult<T> {
  /// Allows the variants below to be `const`.
  const RecvResult();
}

/// The channel delivered a value.
///
/// Canon's `Z_OK`: a value was taken out of the channel's buffer, and [value]
/// is it.
final class RecvData<T> extends RecvResult<T> {
  /// Wraps the [value] the channel delivered.
  const RecvData(this.value);

  /// The value the channel delivered.
  final T value;
}

/// The channel is alive; its buffer is empty right now.
///
/// Canon's `Z_CHANNEL_NODATA`, whose own words are: *"the channel is still
/// alive, but its buffer is empty"* -- so a later call may well succeed. This
/// is the "back off and try again" arm of a polling loop, never a reason to
/// stop.
///
/// Never produced by a blocking receive, which waits instead of reporting an
/// empty buffer.
final class RecvEmpty<T> extends RecvResult<T> {
  /// The alive-but-empty state carries no payload.
  const RecvEmpty();
}

/// The channel was dropped; nothing will ever arrive.
///
/// Canon's `Z_CHANNEL_DISCONNECTED`, whose own words are: *"channel was
/// dropped"*. The producing end is gone -- its subscriber was undeclared or
/// its session closed -- and the state is terminal: every subsequent call
/// reports it again. This is the exit condition of a polling loop.
final class RecvDisconnected<T> extends RecvResult<T> {
  /// The terminal state carries no payload.
  const RecvDisconnected();
}
