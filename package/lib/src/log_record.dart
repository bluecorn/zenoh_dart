import 'package:zenoh_dart/src/log_severity.dart';

/// One log record emitted by zenoh's own runtime, delivered to a host sink.
///
/// ⚠️ **Two fields, and that is not a simplification.** Zenoh's Rust logger
/// carries a target, a file, a line, a thread and a tracing span; zenoh-c's
/// callback signature drops all of them and passes only the level and the
/// rendered message. Nothing this binding could do would recover them, so a
/// host sink cannot key on target or filter by module. Said here because the
/// obvious assumption — *"it is a log record, so it has a target"* — is wrong
/// and would be discovered late.
///
/// The [message] is canon's own rendered text. It is **not** sanitised: see
/// `Zenoh.initLogWithSink` for what it can contain.
class LogRecord {
  /// Creates a record with the given [severity] and [message].
  const LogRecord(this.severity, this.message);

  /// The level canon emitted this record at.
  final LogSeverity severity;

  /// Canon's rendered message text.
  final String message;

  @override
  String toString() => 'LogRecord(${severity.name}): $message';
}
