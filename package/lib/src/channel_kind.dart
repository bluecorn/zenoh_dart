/// Which bounded channel backs a pull handle — and therefore what happens when
/// it fills up.
///
/// One enum for one axis, across every carrier that has a channel mode:
/// `Session.declarePullSubscriber` and
/// `Session.declarePullLivelinessSubscriber` (samples), `Session.pullGet`,
/// `Querier.pullGet` and `Session.pullLivelinessGet` (replies), and
/// `Session.declarePullQueryable` (queries). The kind means the same thing on
/// all six.
///
/// Canon ships two, and the difference is the whole point of the choice:
/// one drops data to keep the producer running, the other stalls the
/// producer to keep every sample. There is no third option and no "unbounded"
/// option — a bounded channel is what a pull surface is.
///
/// ⚠️ [value] is **our shim's dispatch code, not a canon wire value.** Canon
/// has no channel-kind enum at all: it ships two separately-named constructor
/// pairs (`z_ring_channel_sample_new`, `z_fifo_channel_sample_new`) over two
/// distinct handler types, and the kind is chosen by which symbol you call.
/// Dart cannot select a C symbol at run time across the FFI seam, so the kind
/// crosses as an int and the shim dispatches on it. That makes these numbers
/// an internal contract between our two layers, which is exactly why they are
/// written out explicitly instead of being taken from declaration order.
///
/// This enum is send-only: canon exposes no accessor that returns a channel
/// kind, so there is deliberately no `fromWire` decoder — one could never be
/// driven by a real value, and an untestable decoder is worse than none.
enum ChannelKind {
  /// Bounded and **lossy**: when the buffer is full the oldest entry is
  /// dropped to make room.
  ///
  /// The producer is never blocked, so a slow consumer costs data rather than
  /// throughput. This is the shipped default and the kind canon's own
  /// `z_pull.c` example uses.
  ///
  /// On disconnect a ring **discards** whatever it still holds: once the
  /// producer dies, an unread buffered sample is gone rather than drainable.
  ring(0),

  /// Bounded and **lossless**: when the buffer is full the producer blocks
  /// until the consumer takes something out.
  ///
  /// Nothing is dropped, so a slow consumer costs throughput rather than data.
  ///
  /// On disconnect a fifo **drains**: calls keep delivering the samples it
  /// still holds and only report disconnected once it is empty. That is the
  /// opposite of [ring], it is canon's own behaviour measured at 1.8.0, and
  /// it is rendered here unsmoothed rather than papered over.
  ///
  /// ⚠️ **Never publish into a full fifo from the session that owns the
  /// subscriber.** Same-session delivery pushes into the channel on the
  /// *publisher's own thread*, so a single thread acting as both producer and
  /// only consumer blocks inside the put permanently — measured at canon
  /// (zenoh-c 1.8.0: the third put into a capacity-2 same-session fifo never
  /// returned), and unrecoverable from Dart because the call is a synchronous
  /// FFI call. This is canon's backpressure doing exactly its job on the only
  /// thread available; no API design can remove it. Use a second session for
  /// the publisher, or the [ring] kind.
  ///
  /// ⚠️ **At capacity 0 a fifo is a rendezvous, not a one-slot buffer** —
  /// full when empty — so `PullSubscriber.recv()` cannot be used there (its
  /// readiness signal and the blocked delivery wait on each other).
  /// `PullSubscriber.tryRecv()` works normally at capacity 0, because a
  /// synchronous poll is itself the concurrent consumer the rendezvous needs.
  /// Measured at zenoh-c 1.8.0; canon documents nothing about capacity.
  fifo(1);

  const ChannelKind(this.value);

  /// The shim's dispatch code. Explicit; never derived from declaration order.
  final int value;
}
