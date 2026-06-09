import 'dart:typed_data';

/// The kind of a sample (put or delete).
enum SampleKind {
  /// A put sample: data was published.
  put,

  /// A delete sample: data was deleted.
  delete,
}

/// A sample received from a subscriber.
///
/// Contains the key expression, payload, kind, and optional attachment
/// extracted from a zenoh sample notification.
class Sample {
  /// The key expression the sample was published on.
  final String keyExpr;

  /// The payload as a UTF-8 string, decoded leniently.
  ///
  /// Malformed UTF-8 byte sequences are replaced with U+FFFD (the
  /// replacement character). Use [payloadBytes] for the exact data.
  final String payload;

  /// The raw payload bytes.
  final Uint8List payloadBytes;

  /// The kind of sample (put or delete).
  final SampleKind kind;

  /// Optional attachment metadata as a UTF-8 string, decoded leniently.
  ///
  /// Malformed UTF-8 byte sequences are replaced with U+FFFD (the
  /// replacement character).
  final String? attachment;

  /// The raw attachment bytes, or null if no attachment was present.
  ///
  /// This is the exact ground truth for attachment metadata. Use
  /// [attachment] for a lenient UTF-8 string view. A non-null empty
  /// [Uint8List] denotes a present-but-empty attachment (distinct from
  /// null, which denotes an absent attachment).
  final Uint8List? attachmentBytes;

  /// The encoding of the payload as a MIME type string, or null if unknown.
  final String? encoding;

  /// Creates a [Sample] with the given fields.
  Sample({
    required this.keyExpr,
    required this.payload,
    required this.payloadBytes,
    required this.kind,
    this.attachment,
    this.attachmentBytes,
    this.encoding,
  });
}
