/// The consolidation mode for replies to a get query.
///
/// Zenoh-c values: auto=-1, none=0, monotonic=1, latest=2.
/// Use the [value] getter to obtain the zenoh-c integer value.
enum ConsolidationMode {
  /// Let zenoh choose the best consolidation strategy.
  auto(-1),

  /// No consolidation: all replies are returned as-is.
  none(0),

  /// Monotonic consolidation: at most one reply per key expression.
  monotonic(1),

  /// Latest consolidation: only the latest reply per key expression.
  latest(2);

  const ConsolidationMode(this.value);

  /// The zenoh-c integer value for this consolidation mode.
  final int value;
}
