import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/locality.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/query.dart';
import 'package:zenoh_dart/src/reply_keyexpr.dart';
import 'package:zenoh_dart/src/session.dart' show Session;

/// A zenoh queryable that receives queries on a key expression.
///
/// Wraps `z_owned_queryable_t`. Queries are delivered asynchronously
/// via a [Stream]. Call [close] when done to undeclare the queryable
/// and release native resources.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// ⛔ **No `NativeFinalizer` is attached to this class**, deliberately: as
/// `Subscriber` — the stream a user holds does not reference this wrapper, so
/// it is collected while still in use.
/// Releasing it explicitly is therefore the only thing that reclaims it.
class Queryable implements Finalizable {
  /// Creates a queryable on the given session and key expression.
  ///
  /// This is called internally by [Session.declareQueryable].
  factory Queryable.declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKeyExpr,
    String keyExprStr, {
    bool complete = false,
    Locality? allowedOrigin,
  }) {
    final size = bindings.zd_queryable_sizeof();
    final ptr = calloc.allocate<Void>(size);

    final channel = QueryChannel.create();

    final rc = bindings.zd_declare_queryable(
      ptr.cast(),
      loanedSession.cast(),
      loanedKeyExpr.cast(),
      channel.receivePort.sendPort.nativePort,
      complete ? 1 : 0,
      allowedOrigin?.value ?? -1,
    );

    if (rc != 0) {
      channel.abandon();
      calloc.free(ptr);
      throw ZenohException('Failed to declare queryable', rc);
    }

    return Queryable._(ptr, channel, keyExprStr);
  }

  Queryable._(this._ptr, this._channel, this._keyExpr);

  final Pointer<Void> _ptr;
  final QueryChannel _channel;
  final String _keyExpr;
  bool _closed = false;

  /// A stream of [Query]s received by this queryable.
  ///
  /// ⚠️ **UNBOUNDED, and pausing it does not stop the flow.** Queries are
  /// pushed in as they arrive, and each one holds a `z_owned_query_t` clone
  /// open until disposed — so a slow consumer here grows native memory as
  /// well as the Dart queue. Measured: a paused push queryable retained all
  /// **64** queries fired at it, against **9** for
  /// `Session.declarePullQueryable(…, capacity: 8).stream`.
  /// ⚠️ **A value this binding cannot convert arrives as a STREAM ERROR, never
  /// as empty or absent data.** Zenoh can hand over a payload or attachment
  /// the conversion step refuses; delivering that as a zero-length value would
  /// be indistinguishable from a legitimately empty one, and empty is a real
  /// value on this path. The error carries canon's own code.
  ///
  /// ⛔ **The stream keeps running.** A conversion failure is a failed *call*,
  /// not a dead channel — the same rule the pull family already ships — so
  /// later values still arrive and terminating on the first bad one would
  /// lose them. ⚠️ But an unhandled stream error is still an unhandled error:
  /// pass `onError` (or `handleError`), because an unhandled one can take the
  /// program down.
  Stream<Query> get stream => _channel.stream;

  /// The key expression this queryable is declared on.
  String get keyExpr => _keyExpr;

  /// Undeclares the queryable and releases native resources.
  ///
  /// Any query that arrived but was never delivered to a listener is
  /// **dropped**, not delivered. Dropping a query is remotely visible: canon
  /// sends the getter its `ResponseFinal` when the `z_owned_query_t` is
  /// dropped, so a querier sees its query finalised promptly instead of
  /// waiting out its timeout. That is the intended behaviour of a closed
  /// queryable — the alternative is a native block nobody can ever free.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    // Undeclare FIRST: once canon has dropped the closure no further query is
    // posted, so the drain below faces a bounded queue rather than a moving
    // target.
    bindings.zd_queryable_drop(_ptr.cast());
    _channel.closeAndDrain();
    calloc.free(_ptr);
  }
}

/// The NativePort -> [Query] delivery channel behind a queryable.
///
/// Owns the [ReceivePort], the [StreamController], and — the reason this is a
/// class rather than a record — the set of [Query] objects that have been
/// parsed off the port but not yet handed to a listener.
///
/// That set is what [closeAndDrain] has to dispose. The native
/// `z_owned_query_t` rides the port message as a bare integer, so a query that
/// reaches neither the consumer nor `Query.dispose()` has no other owner: both
/// its contents and its shim-malloc'd block are orphaned.
@internal
class QueryChannel {
  /// Sets up the port and controller, and starts parsing incoming NativePort
  /// query messages into [Query] objects.
  ///
  /// The caller passes `receivePort.sendPort.nativePort` to the C shim and, on
  /// a failed declaration, calls [abandon]. A null message is the
  /// stream-completion sentinel (posted by the background-queryable drop when
  /// the session closes); the handle-based path never posts it and instead
  /// closes explicitly via [closeAndDrain].
  factory QueryChannel.create() {
    final receivePort = ReceivePort();
    final controller = StreamController<Query>();
    final channel = QueryChannel._(receivePort, controller);

    receivePort.listen((dynamic message) {
      if (message == null) {
        // Session-close sentinel for a background queryable. Queries still
        // buffered here are NOT dropped: unlike close(), the consumer can
        // still receive them from the closing controller. Whether a session
        // close should cascade a drop into its children is the lifecycle
        // question seed #11 owns; deciding it here would pre-empt that.
        receivePort.close();
        unawaited(controller.close());
        return;
      }
      if (message is! List) return;

      final queryPtr = message[0] as int;
      // Length-carried key expression (interior NUL survives); the selector
      // parameters beside it are now length-carried too.
      final keyExpr = utf8.decode(
        message[1] as Uint8List,
        allowMalformed: true,
      );
      // Length-carried like the key expression above (seed #6's parameters
      // rebase): an interior NUL in the selector's parameters segment is a
      // value, and a kString would have been measured with strlen at this
      // seam. Lenient, like every other display string on a receive surface.
      final params = utf8.decode(
        message[2] as Uint8List,
        allowMalformed: true,
      );
      // ⛔ A VALUE THAT COULD NOT BE CONVERTED IS AN ERROR, NEVER AN
      // EMPTY SUCCESS. The shim used to post a zero-length buffer when
      // canon refused the conversion, which is indistinguishable from a
      // legitimately empty value — and empty is legitimate on every one of
      // these paths. Following the shipped call-failure rule: the error
      // goes to the error channel and the stream KEEPS RUNNING, because a
      // conversion failure is a failed call and not a dead channel.
      final payloadFailure = undecodableRc(message[3]);
      if (payloadFailure != null) {
        controller.addError(undecodableError('a payload', payloadFailure));
        return;
      }
      final attachmentFailure = undecodableRc(message[4]);
      if (attachmentFailure != null) {
        controller.addError(
          undecodableError('an attachment', attachmentFailure),
        );
        return;
      }
      final payloadBytes = message[3] as Uint8List?;
      final attachmentBytes = message[4] as Uint8List?;
      // Length-guarded: encoding is appended at index 5 (defensive against
      // array-length drift). Absent encoding posts kNull -> null here.
      // Length-carried like the two values above: a rendered MIME string is an
      // arbitrary byte sequence and a kString would be measured with strlen at
      // this seam. The lenient String is a display view; encodingBytes is the
      // ground truth.
      final encodingBytes = message.length > 5
          ? message[5] as Uint8List?
          : null;
      // Length-guarded: accepts-replies policy is appended at index 6 as an
      // int (z_reply_keyexpr_t). Absent -> default matchingQuery.
      final acceptsRaw = message.length > 6 ? message[6] as int : null;

      final query = Query(
        handle: queryPtr,
        keyExpr: keyExpr,
        parameters: params,
        payloadBytes: payloadBytes,
        attachmentBytes: attachmentBytes,
        encoding: encodingBytes != null
            ? utf8.decode(encodingBytes, allowMalformed: true)
            : null,
        encodingBytes: encodingBytes,
        acceptsReplies: acceptsRaw != null
            ? ReplyKeyExpr.fromWire(acceptsRaw)
            : ReplyKeyExpr.matchingQuery,
      );

      if (controller.isClosed) {
        // Drain branch: closeAndDrain() already ran and this message was still
        // sitting in the port queue. Nobody can ever receive it, so release it
        // here instead of orphaning the block.
        query.dispose();
        return;
      }

      channel._undelivered.add(query);
      controller.add(query);
    });

    return channel;
  }

  QueryChannel._(this.receivePort, this._controller);

  /// The port the C shim posts query messages to.
  final ReceivePort receivePort;

  final StreamController<Query> _controller;

  /// Queries parsed off the port that no listener has received yet.
  ///
  /// Identity-based: two distinct queries are never "equal".
  final Set<Query> _undelivered = Set<Query>.identity();

  /// Queries as the consumer sees them.
  ///
  /// Passing through this filter **is** delivery — a query still buffered in
  /// the controller has not run it yet, which is what makes [_undelivered]
  /// exact. It doubles as the suppression point: [closeAndDrain] disposes the
  /// undelivered queries and clears the set, so any that the closing
  /// controller still flushes are filtered out rather than handed over
  /// already-disposed.
  Stream<Query> get stream => _controller.stream.where(_undelivered.remove);

  /// Tears the channel down when the declaration itself failed — no query can
  /// have arrived, so there is nothing to drain.
  void abandon() {
    receivePort.close();
    unawaited(_controller.close());
  }

  /// Disposes every query that arrived but was never delivered, then closes.
  ///
  /// Two halves, because a query can be stranded in either of two places:
  ///
  /// 1. **Controller buffer** — parsed into a [Query] but not yet delivered.
  ///    Disposed directly from [_undelivered].
  /// 2. **Port queue** — still an unparsed NativePort message. MEASURED:
  ///    closing the port in the same turn discards these (probe: 0 of 5
  ///    delivered), while deferring the close by one event-loop turn delivers
  ///    them (5 of 5). So the close is deferred, and the listener's
  ///    `controller.isClosed` branch drops each one as it arrives.
  void closeAndDrain() {
    for (final query in _undelivered) {
      query.dispose();
    }
    _undelivered.clear();
    // isClosed flips synchronously here — that is what arms the listener's
    // drain branch for half 2 below.
    unawaited(_controller.close());
    unawaited(Future<void>(receivePort.close));
  }
}
