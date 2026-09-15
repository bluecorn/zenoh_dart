import 'package:zenoh_dart/src/exceptions.dart' show ZenohException;
import 'package:zenoh_dart/src/keyexpr.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/unstable/advanced_publisher.dart';
import 'package:zenoh_dart/src/unstable/advanced_subscriber.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

/// Advanced pub/sub declaration on [Session] — the unstable door.
///
/// These methods are in scope only when `zenoh_unstable.dart` is imported. A
/// stable-door consumer cannot even name them (compile error) — that is the
/// API partition, enforced by the compiler. The runtime [requireUnstable]
/// gate covers the orthogonal case of an unstable import against a stable
/// native.
extension AdvancedSession on Session {
  /// Declares an advanced publisher on the given [keyExpr].
  ///
  /// Returns an [AdvancedPublisher] with optional cache, publisher detection,
  /// and sample miss detection capabilities. Call [AdvancedPublisher.close]
  /// when done.
  ///
  /// [keyExpr] is a `String` or a [KeyExpr], including a declared one.
  ///
  /// Throws [UnsupportedError] if the loaded native lacks the unstable API —
  /// that gate runs FIRST, before the key expression is even looked at.
  /// Throws [ArgumentError] if [keyExpr] is neither a `String` nor a [KeyExpr],
  /// or if the cache bound is negative — checked before any native call.
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  AdvancedPublisher declareAdvancedPublisher(
    Object keyExpr, {
    AdvancedPublisherOptions? options,
  }) {
    requireUnstable();
    final opts = options ?? const AdvancedPublisherOptions();
    // CONV-4(a): the cache bound's domain is checked HERE, before the key
    // expression is loaned, so a negative bound costs no native call at all.
    final maxSamples = opts.cache?.maxSamples;
    if (maxSamples != null && maxSamples < 0) {
      throw ArgumentError.value(
        maxSamples,
        'maxSamples',
        "must be >= 0; null leaves canon's own default in place",
      );
    }
    // The extension does not re-implement the loan; the union seam owns it.
    return withLoanedKeyExpr(keyExpr, 'keyExpr', (loanedKe) {
      return AdvancedPublisher.declare(
        loanedHandle,
        loanedKe,
        keyExprString(keyExpr, 'keyExpr'),
        enableCache: opts.cache != null,
        cacheMaxSamples: maxSamples,
        publisherDetection: opts.publisherDetection,
        sampleMissDetection: opts.sampleMissDetection,
        heartbeatMode: opts.heartbeatMode,
        heartbeatPeriodMs: opts.heartbeatPeriodMs,
        enableMatchingListener: opts.enableMatchingListener,
      );
    });
  }

  /// Declares an advanced subscriber on the given [keyExpr].
  ///
  /// Returns an [AdvancedSubscriber] with optional history recovery,
  /// late publisher detection, sample recovery, and miss detection
  /// capabilities. Call [AdvancedSubscriber.close] when done.
  ///
  /// [keyExpr] is a `String` or a [KeyExpr], including a declared one.
  ///
  /// Throws [UnsupportedError] if the loaded native lacks the unstable API —
  /// that gate runs FIRST, before the key expression is even looked at.
  /// Throws [ArgumentError] if [keyExpr] is neither a `String` nor a [KeyExpr].
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  AdvancedSubscriber declareAdvancedSubscriber(
    Object keyExpr, {
    AdvancedSubscriberOptions options = const AdvancedSubscriberOptions(),
  }) {
    requireUnstable();
    return withLoanedKeyExpr(keyExpr, 'keyExpr', (loanedKe) {
      return AdvancedSubscriber.declare(
        loanedHandle,
        loanedKe,
        keyExprString(keyExpr, 'keyExpr'),
        options: options,
      );
    });
  }
}
