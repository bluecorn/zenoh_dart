/// Severity of a zenoh log record, and the ceiling a host sink installs at.
///
/// The values mirror canon's `zc_log_severity_t` and are **declared
/// explicitly** rather than left to declaration order: the number crosses the
/// FFI seam, so an accidental reorder would silently remap every record
/// instead of failing to compile.
enum LogSeverity {
  /// Very low priority, often extremely verbose.
  trace(0),

  /// Lower priority information.
  debug(1),

  /// Useful information.
  info(2),

  /// Hazardous situations.
  warn(3),

  /// Very serious errors.
  error(4);

  const LogSeverity(this.wireValue);

  /// The value canon uses on the wire.
  final int wireValue;

  /// The severity for [wireValue], or [LogSeverity.error] if canon ever adds
  /// a level this binding does not know.
  ///
  /// ⚠️ **Degrades UPWARD on purpose.** An unknown level is far more likely to
  /// be something new and serious than something new and chatty, and a record
  /// a host never sees because it was mapped to `trace` is worse than one
  /// they see and ignore. The case is unreachable at the pinned zenoh-c:
  /// canon defines exactly these five.
  static LogSeverity fromWire(int wireValue) {
    for (final severity in values) {
      if (severity.wireValue == wireValue) return severity;
    }
    return LogSeverity.error;
  }
}
