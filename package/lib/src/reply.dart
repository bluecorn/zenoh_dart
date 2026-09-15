import 'dart:typed_data';

import 'package:zenoh_dart/src/entity_global_id.dart';
import 'package:zenoh_dart/src/sample.dart';

/// An error payload returned by a queryable instead of a successful reply.
class ReplyError {
  /// Creates a [ReplyError] with the given fields.
  ReplyError({
    required this.payloadBytes,
    required this.payload,
    this.encoding,
    this.encodingBytes,
  });

  /// The raw error payload bytes (exact, byte-faithful).
  final Uint8List payloadBytes;

  /// The error payload decoded as a UTF-8 string for display.
  ///
  /// Decoding is lenient: invalid UTF-8 sequences are replaced with
  /// U+FFFD (the replacement character). Use [payloadBytes] for the
  /// exact bytes.
  final String payload;

  /// The encoding of the error payload, or null if unspecified.
  ///
  /// A lenient MIME display string, delivered length-carried so an interior
  /// NUL survives rather than truncating at the seam. Use [encodingBytes] for
  /// the exact data.
  final String? encoding;

  /// The raw bytes of the rendered encoding, or null if none was carried.
  ///
  /// This is the exact ground truth for the encoding channel; [encoding] is a
  /// lenient UTF-8 string view of these same bytes. A non-null empty
  /// [Uint8List] denotes a present-but-empty encoding, distinct from null.
  final Uint8List? encodingBytes;
}

/// A reply received from a get operation, representing either a successful
/// sample or an error.
class Reply {
  /// Creates an ok reply containing a [Sample].
  Reply.ok(Sample sample, {this.replierId}) : _sample = sample, _error = null;

  /// Creates an error reply containing a [ReplyError].
  Reply.error(ReplyError error, {this.replierId})
    : _sample = null,
      _error = error;
  final Sample? _sample;
  final ReplyError? _error;

  /// The entity that answered this reply, or null if unavailable (e.g. the
  /// unstable API is compiled out). Present for both ok and error replies.
  final EntityGlobalId? replierId;

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
