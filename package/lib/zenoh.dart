/// Dart bindings for the Zenoh pub/sub/query protocol via FFI.
///
/// ⛔ EVERY DIRECTIVE BELOW ALLOW-LISTS. A bare `export 'src/x.dart';` hands
/// out every public declaration that file will EVER carry, so a helper added
/// to it in some later unit joins this package's public API with nobody
/// having decided that. A `show` clause makes the decision explicit and
/// makes each addition to it a reviewable line.
///
/// ⚠️ SO AN EXCLUSION IS NOW AN OMISSION, NOT A CLAUSE. The names called out
/// in the comments below are not fenced by a `hide` any more; they are
/// simply absent from a `show`. Nothing else marks them, which is why each
/// one is named here with its ground.
///
/// The lists are derived from the per-file public-declaration census
/// (`scripts/instruments/export_surface.dart`), not written by
/// hand, and are sorted the way `combinators_ordering` wants them: plain
/// case-sensitive comparison, so uppercase sorts before lowercase.
library;

export 'src/bytes.dart' show ZBytes;
export 'src/bytes_writer.dart' show ZBytesWriter;
export 'src/channel_kind.dart' show ChannelKind;
export 'src/config.dart' show Config;
// Shows the enum only. `requireCongestionControlSupported` is left out: it is
// the @internal send-site guard that refuses blockFirst on a native without
// the unstable API, not public surface.
export 'src/congestion_control.dart' show CongestionControl;
export 'src/consolidation_mode.dart' show ConsolidationMode;
export 'src/deserializer.dart' show ZDeserializer;
// Shows the type only. `encodingWireChannels` is left out: it is the
// send-site RAW (mime, schema) accessor shared across the src/ files, not
// public surface.
export 'src/encoding.dart' show Encoding;
export 'src/entity_global_id.dart' show EntityGlobalId;
// Shows the exception only. `undecodableError` and `undecodableRc` are left
// out: they are @internal receive-path helpers shared across the src/ files,
// not public surface.
export 'src/exceptions.dart' show ZenohException;
export 'src/hello.dart' show Hello;
export 'src/id.dart' show ZenohId;
// Shows the type only. `keyExprString` and `withLoanedKeyExpr` are left out:
// they are @internal argument-union helpers shared across the src/ files,
// not public surface.
export 'src/keyexpr.dart' show KeyExpr;
export 'src/liveliness.dart' show LivelinessToken;
export 'src/locality.dart' show Locality;
export 'src/log_record.dart' show LogRecord;
export 'src/log_severity.dart' show LogSeverity;
export 'src/priority.dart' show Priority;
export 'src/publisher.dart' show Publisher;
export 'src/pull_queryable.dart' show PullQueryable;
export 'src/pull_replies.dart' show PullReplies;
export 'src/pull_subscriber.dart' show PullSubscriber;
export 'src/querier.dart' show Querier;
export 'src/query.dart' show Query;
export 'src/query_target.dart' show QueryTarget;
// Shows the type only. `QueryChannel` is left out: it is the queryable's
// internal NativePort plumbing (Session's background-queryable path shares
// it), not public surface.
export 'src/queryable.dart' show Queryable;
// ⭐ WRAPPED ON PURPOSE, AND NOT BECAUSE A LINT ASKED.
// `lines_longer_than_80_chars` EXEMPTS an export directive — measured, an
// 85-column `export … show …;` draws nothing while an 82-column ordinary
// line draws the lint in the same run. The wrap is required by a cell in
// `api_surface_test.dart`, so that the door census's directive parser is
// exercised by a real door and not only by its own fixtures. This directive
// is the one chosen because no later step of this unit shortens it.
export 'src/recv_result.dart'
    show RecvData, RecvDisconnected, RecvEmpty, RecvResult;
export 'src/reply.dart' show Reply, ReplyError;
export 'src/reply_keyexpr.dart' show ReplyKeyExpr;
export 'src/sample.dart' show Sample, SampleKind;
export 'src/serializer.dart' show ZSerializer;
// Shows the class only. `completeOpenFromPost`, `openFailureMessage` and
// `openStartFailureMessage` are left out: they are session-open plumbing that
// was public only by accident of a bare `export`, they carry `@internal`
// beside `@visibleForTesting`, and the analyzer REFUSES to export an
// `@internal` top-level element at all — measured, six
// `invalid_export_of_internal_element` warnings across both doors, exit 2. So
// the omission here and the annotation there are one indivisible change, not
// two.
export 'src/session.dart' show Session;
export 'src/subscriber.dart' show SampleChannel, Subscriber;
export 'src/timestamp.dart' show Timestamp;
export 'src/whatami.dart' show WhatAmI;
export 'src/zenoh.dart' show Zenoh;
