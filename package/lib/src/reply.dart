import 'dart:typed_data';

import 'sample.dart';

/// An error payload returned by a queryable instead of a successful reply.
class ReplyError {
  /// The raw error payload bytes (exact, byte-faithful).
  final Uint8List payloadBytes;

  /// The error payload decoded as a UTF-8 string for display.
  ///
  /// Decoding is lenient: invalid UTF-8 sequences are replaced with
  /// U+FFFD (the replacement character). Use [payloadBytes] for the
  /// exact bytes.
  final String payload;

  /// The encoding of the error payload, or null if unspecified.
  final String? encoding;

  /// Creates a [ReplyError] with the given fields.
  ReplyError({
    required this.payloadBytes,
    required this.payload,
    this.encoding,
  });
}

/// A reply received from a get operation, representing either a successful
/// sample or an error.
class Reply {
  final Sample? _sample;
  final ReplyError? _error;

  /// Creates an ok reply containing a [Sample].
  Reply.ok(Sample sample) : _sample = sample, _error = null;

  /// Creates an error reply containing a [ReplyError].
  Reply.error(ReplyError error) : _sample = null, _error = error;

  /// Returns true if this reply contains a successful sample.
  bool get isOk => _sample != null;

  /// Returns the sample if this is an ok reply.
  ///
  /// Throws [StateError] if this is an error reply.
  Sample get ok {
    if (_sample == null) {
      throw StateError('Cannot access ok on an error reply');
    }
    return _sample;
  }

  /// Returns the error if this is an error reply.
  ///
  /// Throws [StateError] if this is an ok reply.
  ReplyError get error {
    if (_error == null) {
      throw StateError('Cannot access error on an ok reply');
    }
    return _error;
  }
}
