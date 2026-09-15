import 'dart:typed_data';

import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/congestion_control.dart';
import 'package:zenoh_dart/src/priority.dart';
import 'package:zenoh_dart/src/timestamp.dart';

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
  /// Creates a [Sample] with the given fields.
  Sample({
    required this.keyExpr,
    required this.payload,
    required this.payloadBytes,
    required this.kind,
    this.attachment,
    this.attachmentBytes,
    this.encoding,
    this.encodingBytes,
    this.timestamp,
    this.priority = Priority.data,
    this.congestionControl = CongestionControl.drop,
    this.express = false,
    this.payloadZBytes,
  });

  /// The key expression the sample was published on.
  ///
  /// Delivered byte-exact: it crosses from native length-carried rather than
  /// as a C string, so an interior NUL — which the key expression grammar
  /// permits and canon carries across the wire — survives here too.
  final String keyExpr;

  /// The payload as a UTF-8 string, decoded leniently.
  ///
  /// Malformed UTF-8 byte sequences are replaced with U+FFFD (the
  /// replacement character). Use [payloadBytes] for the exact data.
  final String payload;

  /// The raw payload bytes.
  final Uint8List payloadBytes;

  /// The payload as a retained [ZBytes] handle, or null when this sample's
  /// carrier did not opt in.
  ///
  /// **Opt in with `retainPayload: true` at declaration.** It is off by
  /// default, so nothing pays for retention that did not ask for it.
  ///
  /// Where [payloadBytes] is a *copy* taken as the sample crossed the seam,
  /// this is an owned handle on the payload itself — a shallow, refcounted
  /// clone of what the network delivered. That is what makes two things
  /// expressible that a copy cannot: republishing the payload without copying
  /// it, and asking what backs it (`isShmBacked`).
  ///
  /// ## Lifetime — and it is YOURS
  ///
  /// The handle **outlives** the delivery callback, the subscriber and the
  /// session it arrived on: it is an independent clone, not a view into
  /// something the carrier owns. Releasing any of them does not invalidate it.
  ///
  /// ⛔ **Release it.** Either [ZBytes.dispose] it, or hand it to a send that
  /// consumes it (`putBytes` marks it consumed and frees it). A `ZBytes`
  /// carries a `NativeFinalizer` safety net, so a dropped handle is reclaimed
  /// when it is collected — but a finalizer runs at an unpredictable time, or
  /// not at all if the program exits first. **The net is not a substitute for
  /// releasing it.**
  ///
  /// ⚠️ Because this holds a native handle, a [Sample] carrying one **cannot
  /// cross an isolate boundary** — the VM refuses it, naming `ZBytes`. A sample
  /// whose `payloadZBytes` is null still sends normally.
  final ZBytes? payloadZBytes;

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

  /// The encoding of the payload as a MIME type string, decoded leniently.
  ///
  /// A display view: malformed UTF-8 byte sequences are replaced with U+FFFD
  /// (the replacement character). Use [encodingBytes] for the exact data.
  ///
  /// Delivered length-carried, so an interior NUL — which canon carries across
  /// the wire byte-exact, since a MIME id or schema built with
  /// `z_encoding_from_substr` may contain one — survives here rather than
  /// truncating at the seam.
  final String? encoding;

  /// The raw bytes of the rendered encoding, or null if none was carried.
  ///
  /// This is the exact ground truth for the encoding channel; [encoding] is a
  /// lenient UTF-8 string view of these same bytes. A non-null empty
  /// [Uint8List] denotes a present-but-empty encoding (distinct from null,
  /// which denotes an absent one), mirroring the [attachment] /
  /// [attachmentBytes] pair.
  ///
  /// On a sample the encoding is never absent — canon always renders one — so
  /// this is non-null in practice; the nullability mirrors [encoding]'s and
  /// the other receive surfaces', where absence is genuinely reachable.
  final Uint8List? encodingBytes;

  /// The [Timestamp] attached to this sample, or null when absent.
  ///
  /// Null denotes a sample that carries no timestamp (the sender did not
  /// attach one and the network did not add one). When present, it is the
  /// bit-exact raw `z_timestamp_t` image, re-sendable without decomposition.
  final Timestamp? timestamp;

  /// The [Priority] the sample was published with.
  ///
  /// Non-nullable: carries the publisher's declared priority (default
  /// [Priority.data] when unspecified) — never absent on the wire.
  final Priority priority;

  /// The [CongestionControl] strategy the sample was published with.
  ///
  /// Non-nullable: carries the publisher's declared strategy (default
  /// [CongestionControl.drop]) — never absent on the wire.
  final CongestionControl congestionControl;

  /// Whether the sample was published in express mode (batching disabled).
  ///
  /// Non-nullable: defaults to false — never absent on the wire.
  final bool express;
}
