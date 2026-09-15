import 'package:meta/meta.dart';

/// Represents the encoding of a zenoh payload.
///
/// Uses MIME type strings to describe the encoding format.
/// Provides predefined constants for common types and supports
/// custom MIME types via the constructor.
///
/// An encoding marshals into two independent channels at a send site: the
/// mime string and an optional schema. Both are held here as a pure value --
/// [withSchema] returns a NEW [Encoding] rather than setting a schema in
/// place, and the type carries no native dependency (it does not import
/// `dart:ffi`). Canon's schema setter is invoked in the C shim at send time,
/// not by this type.
///
/// ## Structural equality diverges from wire equality
///
/// Equality and [hashCode] are structural over [mimeType] and the RAW schema
/// -- exactly the pair that determines the wire -- so `==` means "these two
/// marshal identically". It does NOT mean "these two are the same encoding on
/// the wire": `Encoding('text/plain;utf-8')` and
/// `Encoding.textPlain.withSchema('utf-8')` render identically on the wire
/// and are nonetheless unequal here.
///
/// That divergence is deliberate. Wire equality depends on whether the mime
/// string names a *well-known* id, which requires canon's 53-entry id table
/// and `z_encoding_equals` -- precisely the native dependency this type keeps
/// out. A pure-Dart `==` approximating it would be a silent substitution on
/// the very surface this binding exists to make faithful.
///
/// The consequence for consumers: an encoding received as
/// `'application/json;my-schema'` and rebuilt through `Encoding(...)` will NOT
/// match a `Set` or `Map` key built as
/// `Encoding.applicationJson.withSchema('my-schema')`. Build both sides of
/// such a lookup the same way.
@immutable
class Encoding {
  /// Creates an [Encoding] with the given [mimeType].
  ///
  /// No schema is set explicitly. A schema embedded in [mimeType] after a
  /// `;` separator is still surfaced on read -- see [schema].
  const Encoding(this.mimeType) : _schema = null;

  /// Creates an [Encoding] whose schema was set explicitly.
  const Encoding._(this.mimeType, this._schema);

  /// The MIME type string for this encoding.
  final String mimeType;

  /// The character separating the mime string from a schema composed into
  /// it. Named once because the derived split in [schema] and the
  /// composition in [toString] must agree on it.
  static const _schemaSeparator = ';';

  /// The RAW schema: non-null only when [withSchema] set one.
  ///
  /// This is what feeds the wire's schema channel, never the derived [schema]
  /// getter. Send sites under `lib/src/` reach it through
  /// [encodingWireChannels].
  final String? _schema;

  /// Opaque bytes with no interpretation -- zenoh's default encoding.
  ///
  /// MIME `zenoh/bytes`.
  static const zenohBytes = Encoding('zenoh/bytes');

  /// A UTF-8 string.
  ///
  /// MIME `zenoh/string`.
  static const zenohString = Encoding('zenoh/string');

  /// Plain text.
  ///
  /// MIME `text/plain`.
  static const textPlain = Encoding('text/plain');

  /// A JSON document.
  ///
  /// MIME `application/json`.
  static const applicationJson = Encoding('application/json');

  /// Arbitrary binary data.
  ///
  /// MIME `application/octet-stream`.
  static const applicationOctetStream = Encoding('application/octet-stream');

  /// A Protocol Buffers message.
  ///
  /// MIME `application/protobuf`.
  static const applicationProtobuf = Encoding('application/protobuf');

  /// An HTML document.
  ///
  /// MIME `text/html`.
  static const textHtml = Encoding('text/html');

  /// Comma-separated values.
  ///
  /// MIME `text/csv`.
  static const textCsv = Encoding('text/csv');

  /// A PNG image.
  ///
  /// MIME `image/png`.
  static const imagePng = Encoding('image/png');

  /// A JPEG image.
  ///
  /// MIME `image/jpeg`.
  static const imageJpeg = Encoding('image/jpeg');

  // The rest of canon's predefined table, ordered by MIME string. Kept as its
  // own block so the ten constants above keep the positions they shipped in.
  //
  // GENERATED, NEVER TRANSCRIBED. Identifier, MIME string and summary line are
  // all derived from the pinned `zenoh_commons.h`'s own declarations, summary
  // text included verbatim -- canon's wording, canon's occasional typo. A
  // hand-typed table would be checkable only against itself;
  // `test/encoding_constants_oracle_test.dart` checks this one against the
  // values canon returns at runtime.
  //
  // The identifier is canon's MIME string split on `/`, `+` and `-` and
  // lowerCamelCased. That transform is LOSSY -- all three separators fold to
  // the same word boundary -- so each constant's dartdoc carries the MIME
  // string, which is the only place it can be recovered from.

  /// A Concise Binary Object Representation (CBOR)-encoded data.
  ///
  /// MIME `application/cbor`.
  static const applicationCbor = Encoding('application/cbor');

  /// A Common Data Representation (CDR)-encoded data.
  ///
  /// MIME `application/cdr`.
  static const applicationCdr = Encoding('application/cdr');

  /// Constrained Application Protocol (CoAP) data intended for CoAP-to-HTTP and
  /// HTTP-to-CoAP proxies.
  ///
  /// MIME `application/coap-payload`.
  static const applicationCoapPayload = Encoding('application/coap-payload');

  /// A Java serialized object.
  ///
  /// MIME `application/java-serialized-object`.
  static const applicationJavaSerializedObject = Encoding(
    'application/java-serialized-object',
  );

  /// Defines a JSON document structure for expressing a sequence of operations
  /// to apply to a JSON document.
  ///
  /// MIME `application/json-patch+json`.
  static const applicationJsonPatchJson = Encoding(
    'application/json-patch+json',
  );

  /// A JSON text sequence consists of any number of JSON texts, all encoded in
  /// UTF-8.
  ///
  /// MIME `application/json-seq`.
  static const applicationJsonSeq = Encoding('application/json-seq');

  /// A JSONPath defines a string syntax for selecting and extracting JSON
  /// values from within a given JSON value.
  ///
  /// MIME `application/jsonpath`.
  static const applicationJsonpath = Encoding('application/jsonpath');

  /// A JSON Web Token (JWT).
  ///
  /// MIME `application/jwt`.
  static const applicationJwt = Encoding('application/jwt');

  /// An application-specific MPEG-4 encoded data, either audio or video.
  ///
  /// MIME `application/mp4`.
  static const applicationMp4 = Encoding('application/mp4');

  /// An [openmetrics](https://github.com/OpenObservability/OpenMetrics) data,
  /// common used by [Prometheus](https://prometheus.io/).
  ///
  /// MIME `application/openmetrics-text`.
  static const applicationOpenmetricsText = Encoding(
    'application/openmetrics-text',
  );

  /// A Python object serialized using
  /// [pickle](https://docs.python.org/3/library/pickle.html).
  ///
  /// MIME `application/python-serialized-object`.
  static const applicationPythonSerializedObject = Encoding(
    'application/python-serialized-object',
  );

  /// A SOAP 1.2 message serialized as XML 1.0.
  ///
  /// MIME `application/soap+xml`.
  static const applicationSoapXml = Encoding('application/soap+xml');

  /// An application-specific SQL query.
  ///
  /// MIME `application/sql`.
  static const applicationSql = Encoding('application/sql');

  /// An encoded a list of tuples, each consisting of a name and a value.
  ///
  /// MIME `application/x-www-form-urlencoded`.
  static const applicationXWwwFormUrlencoded = Encoding(
    'application/x-www-form-urlencoded',
  );

  /// An XML file intended to be consumed by an application..
  ///
  /// MIME `application/xml`.
  static const applicationXml = Encoding('application/xml');

  /// YAML data intended to be consumed by an application.
  ///
  /// MIME `application/yaml`.
  static const applicationYaml = Encoding('application/yaml');

  /// A YANG-encoded data commonly used by the Network Configuration Protocol
  /// (NETCONF).
  ///
  /// MIME `application/yang`.
  static const applicationYang = Encoding('application/yang');

  /// A MPEG-4 Advanced Audio Coding (AAC) media.
  ///
  /// MIME `audio/aac`.
  static const audioAac = Encoding('audio/aac');

  /// A Free Lossless Audio Codec (FLAC) media.
  ///
  /// MIME `audio/flac`.
  static const audioFlac = Encoding('audio/flac');

  /// An audio codec defined in MPEG-1, MPEG-2, MPEG-4, or registered at the MP4
  /// registration authority.
  ///
  /// MIME `audio/mp4`.
  static const audioMp4 = Encoding('audio/mp4');

  /// An Ogg-encapsulated audio stream.
  ///
  /// MIME `audio/ogg`.
  static const audioOgg = Encoding('audio/ogg');

  /// A Vorbis-encoded audio stream.
  ///
  /// MIME `audio/vorbis`.
  static const audioVorbis = Encoding('audio/vorbis');

  /// A BitMap (BMP) image.
  ///
  /// MIME `image/bmp`.
  static const imageBmp = Encoding('image/bmp');

  /// A Graphics Interchange Format (GIF) image.
  ///
  /// MIME `image/gif`.
  static const imageGif = Encoding('image/gif');

  /// A Web Portable (WebP) image.
  ///
  /// MIME `image/webp`.
  static const imageWebp = Encoding('image/webp');

  /// A CSS file.
  ///
  /// MIME `text/css`.
  static const textCss = Encoding('text/css');

  /// A JavaScript file.
  ///
  /// MIME `text/javascript`.
  static const textJavascript = Encoding('text/javascript');

  /// JSON data intended to be human readable.
  ///
  /// MIME `text/json`.
  static const textJson = Encoding('text/json');

  /// JSON5 encoded data that are human readable.
  ///
  /// MIME `text/json5`.
  static const textJson5 = Encoding('text/json5');

  /// A MarkDown file.
  ///
  /// MIME `text/markdown`.
  static const textMarkdown = Encoding('text/markdown');

  /// An XML file that is human readable.
  ///
  /// MIME `text/xml`.
  static const textXml = Encoding('text/xml');

  /// YAML data intended to be human readable.
  ///
  /// MIME `text/yaml`.
  static const textYaml = Encoding('text/yaml');

  /// A h261-encoded video stream.
  ///
  /// MIME `video/h261`.
  static const videoH261 = Encoding('video/h261');

  /// A h263-encoded video stream.
  ///
  /// MIME `video/h263`.
  static const videoH263 = Encoding('video/h263');

  /// A h264-encoded video stream.
  ///
  /// MIME `video/h264`.
  static const videoH264 = Encoding('video/h264');

  /// A h265-encoded video stream.
  ///
  /// MIME `video/h265`.
  static const videoH265 = Encoding('video/h265');

  /// A h266-encoded video stream.
  ///
  /// MIME `video/h266`.
  static const videoH266 = Encoding('video/h266');

  /// A video codec defined in MPEG-1, MPEG-2, MPEG-4, or registered at the MP4
  /// registration authority.
  ///
  /// MIME `video/mp4`.
  static const videoMp4 = Encoding('video/mp4');

  /// An Ogg-encapsulated video stream.
  ///
  /// MIME `video/ogg`.
  static const videoOgg = Encoding('video/ogg');

  /// An uncompressed, studio-quality video stream.
  ///
  /// MIME `video/raw`.
  static const videoRaw = Encoding('video/raw');

  /// A VP8-encoded video stream.
  ///
  /// MIME `video/vp8`.
  static const videoVp8 = Encoding('video/vp8');

  /// A VP9-encoded video stream.
  ///
  /// MIME `video/vp9`.
  static const videoVp9 = Encoding('video/vp9');

  /// Zenoh serialized data. This encoding supposes that the payload was created
  /// with serialization functions. The `schema` field may contain the details
  /// of serialziation format.
  ///
  /// MIME `zenoh/serialized`.
  static const zenohSerialized = Encoding('zenoh/serialized');

  /// Returns a copy of this encoding carrying [schema] as its schema.
  ///
  /// Value-style: this [Encoding] is left unchanged and a new one is
  /// returned. [mimeType] is carried over untouched -- the two wire channels
  /// are independent.
  ///
  /// [schema] is a non-nullable positional `String`, by CONV-2b (one entry
  /// point, one parameter -> a parameter, not an options class) and because
  /// there is no "canon decides" case when a caller is explicitly setting a
  /// schema. Passing `''` sets the present-but-empty state, which is a real
  /// canon state distinct from absent (R-4); to express *absent*, do not call
  /// this method at all.
  Encoding withSchema(String schema) => Encoding._(mimeType, schema);

  /// The schema carried by this encoding, or `null` when there is none.
  ///
  /// ## A read convenience -- never a send path
  ///
  /// THE MARSHALLING RULE: the RAW fields feed the wire. [mimeType] goes to
  /// the mime channel verbatim, and the raw schema -- the one [withSchema]
  /// set -- goes to the schema channel. **This getter never feeds a send
  /// path.** Send sites under `lib/src/` take the raw pair from
  /// [encodingWireChannels] instead.
  ///
  /// Marshalling through this getter would corrupt the value: under the
  /// derived reading, `Encoding('foo/bar;')` would go out as mime `foo/bar`
  /// plus an empty schema and arrive as `'foo/bar'`, where the wire must
  /// carry `'foo/bar;'`.
  ///
  /// ## Resolution order
  ///
  /// 1. the raw schema, when [withSchema] set one -- an explicit schema
  ///    always wins over a derived one;
  /// 2. otherwise the tail after the FIRST `;` in [mimeType], when there is
  ///    one. That split is a Dart-side display convention, NOT a mirror of
  ///    canon's parse: measured, canon stores an unrecognised composed string
  ///    whole and unsplit, under a custom id;
  /// 3. otherwise `null`.
  ///
  /// ## Nullability
  ///
  /// `String?` per CONV-2: `null` means *unspecified, canon decides* -- no
  /// schema field is set -- and never a binding-chosen default. `''` is a
  /// different state, present-but-empty, rendered as a bare trailing `;`.
  /// `null` therefore stands for exactly one state, as the sealed-result
  /// convention (S4) requires of new nullable surface.
  String? get schema {
    final raw = _schema;
    if (raw != null) return raw;
    final separator = mimeType.indexOf(_schemaSeparator);
    if (separator < 0) return null;
    return mimeType.substring(separator + 1);
  }

  /// Renders this encoding the way canon composes one, so display and wire
  /// agree.
  ///
  /// With no raw schema, [mimeType] verbatim. Otherwise [mimeType] up to but
  /// excluding its first `;`, then `;`, then the raw schema -- canon's
  /// `z_encoding_set_schema_from_substr` REPLACES rather than appends, so
  /// `Encoding('text/plain;old').withSchema('new')` renders `text/plain;new`
  /// and agrees with what the wire carries. A naive concatenation would
  /// render `text/plain;old;new` and contradict it.
  @override
  String toString() {
    final raw = _schema;
    if (raw == null) return mimeType;
    final separator = mimeType.indexOf(_schemaSeparator);
    final base = separator < 0 ? mimeType : mimeType.substring(0, separator);
    return '$base$_schemaSeparator$raw';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Encoding &&
          mimeType == other.mimeType &&
          _schema == other._schema;

  @override
  int get hashCode => Object.hash(mimeType, _schema);
}

/// The two independent channels an [Encoding] marshals into at a send site.
///
/// Returns the RAW pair, never the derived view: `mimeType` verbatim, and the
/// schema only if one was set explicitly through [Encoding.withSchema]. See
/// the marshalling rule on [Encoding.schema] for why this distinction is
/// load-bearing.
///
/// Deliberately NOT part of the package's public API -- `zenoh.dart` hides it.
/// Send sites under `lib/src/` import this file directly and call it.
@internal
(String mime, String? schema) encodingWireChannels(Encoding e) =>
    (e.mimeType, e._schema);
