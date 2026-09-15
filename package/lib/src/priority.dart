/// The priority of a zenoh message.
///
/// Values are ordered from highest priority ([realTime]) to lowest
/// ([background]). The zenoh-c integer values are `index + 1` (1–7).
enum Priority {
  /// Highest priority (wire value 1), for latency-critical control traffic.
  realTime(1),

  /// High-priority interactive traffic (wire value 2).
  interactiveHigh(2),

  /// Lower-priority interactive traffic (wire value 3).
  interactiveLow(3),

  /// High-priority data traffic (wire value 4).
  dataHigh(4),

  /// Default data priority (wire value 5).
  data(5),

  /// Low-priority data traffic (wire value 6).
  dataLow(6),

  /// Lowest priority (wire value 7), yielding to all other traffic.
  background(7);

  const Priority(this.value);

  /// The zenoh-c wire value. Explicit; never derived from declaration order.
  final int value;

  /// Decodes a zenoh-c wire priority value (1–7) into a [Priority].
  ///
  /// The wire domain is `1..7`, mapped to the 7 members via `raw - 1`. Any
  /// out-of-range value falls back to [Priority.data] (`Z_PRIORITY_DEFAULT`)
  /// rather than crashing on an unbounded index.
  static Priority fromWire(int raw) {
    final index = raw - 1;
    if (index < 0 || index >= Priority.values.length) return Priority.data;
    return Priority.values[index];
  }
}
