import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/channel_kind.dart';
import 'package:zenoh_dart/src/congestion_control.dart';
import 'package:zenoh_dart/src/consolidation_mode.dart';
import 'package:zenoh_dart/src/encoding.dart';
import 'package:zenoh_dart/src/entity_global_id.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/id.dart';
import 'package:zenoh_dart/src/locality.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/native_string.dart';
import 'package:zenoh_dart/src/priority.dart';
import 'package:zenoh_dart/src/pull_replies.dart';
import 'package:zenoh_dart/src/query_target.dart';
import 'package:zenoh_dart/src/reply.dart';
import 'package:zenoh_dart/src/reply_keyexpr.dart';
import 'package:zenoh_dart/src/reply_retention.dart';
import 'package:zenoh_dart/src/sample.dart';
import 'package:zenoh_dart/src/session.dart' show Session;
import 'package:zenoh_dart/src/timestamp.dart';

/// A zenoh querier for efficiently sending multiple queries on a single
/// key expression with pre-configured options.
///
/// Wraps `z_owned_querier_t`. Call [close] when done to undeclare the
/// querier and release native resources.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// ⛔ **No `NativeFinalizer` is attached to this class**, deliberately: a
/// `get()` hands the caller a `Stream<Reply>` whose listener captures the port
/// and controller, NOT the querier — so the querier is unreferenced while its
/// query is in flight, and releasing it there terminates the get with zero
/// replies.
/// Releasing it explicitly is therefore the only thing that reclaims it.
class Querier implements Finalizable {
  /// Creates a querier on the given session and key expression.
  ///
  /// This is called internally by [Session.declareQuerier].
  ///
  /// [congestionControl], [priority], [isExpress], [allowedDestination] and
  /// [acceptReplies] are each optional; omitting one — or passing `null` —
  /// means **canon decides**. A querier is a *request* path, so canon's
  /// congestion default here is [CongestionControl.block]; the others are
  /// [Priority.data], `isExpress: false`, [Locality.any] and
  /// [ReplyKeyExpr.matchingQuery].
  ///
  /// All five are fixed at DECLARATION time and apply to every [get] this
  /// querier sends. canon's `z_querier_get_options_t` carries no QoS, locality
  /// or accept-replies field, so there is deliberately no per-call form.
  ///
  /// ⚠️ Read [CongestionControl] before selecting [CongestionControl.block].
  factory Querier.declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKeyExpr,
    String keyExpr, {
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Duration? timeout,
    CongestionControl? congestionControl,
    Priority? priority,
    bool? isExpress,
    Locality? allowedDestination,
    ReplyKeyExpr? acceptReplies,
    bool enableMatchingListener = false,
  }) {
    final size = bindings.zd_querier_sizeof();
    final ptr = calloc.allocate<Void>(size);

    final rc = bindings.zd_declare_querier(
      ptr.cast(),
      loanedSession.cast(),
      loanedKeyExpr.cast(),
      target.index,
      consolidation.value,
      timeout != null ? timeout.inMilliseconds : 0,
      congestionControl?.value ?? -1,
      priority?.value ?? -1,
      isExpress == null ? -1 : (isExpress ? 1 : 0),
      allowedDestination?.value ?? -1,
      acceptReplies?.value ?? -1,
    );

    if (rc != 0) {
      calloc.free(ptr);
      throw ZenohException('Failed to declare querier', rc);
    }

    ReceivePort? matchingPort;
    StreamController<bool>? matchingController;

    if (enableMatchingListener) {
      matchingPort = ReceivePort();
      matchingController = StreamController<bool>();

      matchingPort.listen((dynamic message) {
        if (message is int) {
          matchingController!.add(message != 0);
        }
      });

      final mlRc = bindings.zd_querier_declare_background_matching_listener(
        ptr.cast(),
        matchingPort.sendPort.nativePort,
      );

      if (mlRc != 0) {
        matchingPort.close();
        unawaited(matchingController.close());
        bindings.zd_querier_drop(ptr.cast());
        calloc.free(ptr);
        throw ZenohException('Failed to declare matching listener', mlRc);
      }
    }

    return Querier._(ptr, keyExpr, matchingPort, matchingController);
  }

  Querier._(
    this._ptr,
    this._keyExpr,
    this._matchingPort,
    this._matchingController,
  );

  final Pointer<Void> _ptr;
  final String _keyExpr;
  bool _closed = false;
  final ReceivePort? _matchingPort;
  final StreamController<bool>? _matchingController;

  /// The key expression this querier is declared on.
  String get keyExpr {
    if (_closed) throw StateError('Querier has been closed');
    return _keyExpr;
  }

  /// Sends a query via this querier, with replies landing in a **bounded
  /// channel** instead of a stream.
  ///
  /// The channel-mode sibling of [get], carrying its identical option surface.
  /// [kind] and [capacity] are required, deliberately: canon forces the caller
  /// to choose both, so this binding substitutes no value canon does not have.
  ///
  /// The handle's release is [PullReplies.dispose] — local only, because the
  /// query still runs to completion natively and no peer observes the drop.
  ///
  /// The declaration-time options this querier was created with (target,
  /// consolidation, timeout) apply here exactly as they do to [get]; canon's
  /// per-get options struct carries no timeout field, so a sentinel timeout is
  /// refused at `Session.declareQuerier` rather than here.
  ///
  /// ⚠️ The same-session freeze and the ring's discard-at-disconnect apply
  /// exactly as on `Session.pullGet` — see there.
  ///
  /// Throws [ArgumentError] if [capacity] is negative.
  /// Throws [StateError] if the querier has been closed.
  PullReplies pullGet({
    required ChannelKind kind,
    required int capacity,
    String? parameters,
    ZBytes? payload,
    Encoding? encoding,
    ZBytes? attachment,

    /// Whether each pulled OK reply carries a retained
    /// [Sample.payloadZBytes]. Off by default; the ERROR arm never does.
    bool retainPayload = false,
  }) {
    if (_closed) throw StateError('Querier is closed');
    // BEFORE ANY NATIVE CALL: a negative is outside canon's `size_t` domain,
    // and the carriage would otherwise reinterpret it as an enormous unsigned
    // capacity -- a silent transform, not a refusal.
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be non-negative');
    }

    final handlerHandle = calloc<Uint8>(
      bindings.zd_reply_handler_sizeof(kind.value),
    );
    final receivePort = ReceivePort();
    final teeOut = calloc<Pointer<Uint8>>();
    Pointer<Uint8> teeValue = nullptr;
    var started = false;
    // LENGTH-CARRIED, as on the stream sibling.
    Pointer<Char> parametersNative = nullptr;
    var parametersLen = 0;
    // The encoding joins parameters on the length-carried side: two
    // INDEPENDENT channels, from the RAW pair (R-3a).
    Pointer<Char> encodingNative = nullptr;
    var encodingLen = 0;
    Pointer<Char> schemaNative = nullptr;
    var schemaLen = 0;

    try {
      final marshalled = allocLengthCarriedUtf8(parameters);
      parametersNative = marshalled.ptr;
      parametersLen = marshalled.len;
      final (mime, schema) = encoding != null
          ? encodingWireChannels(encoding)
          : (null, null);
      final encMarshalled = allocLengthCarriedUtf8(mime);
      encodingNative = encMarshalled.ptr;
      encodingLen = encMarshalled.len;
      final schemaMarshalled = allocLengthCarriedUtf8(schema);
      schemaNative = schemaMarshalled.ptr;
      schemaLen = schemaMarshalled.len;

      final rc = bindings.zd_querier_get_channel(
        handlerHandle,
        teeOut,
        receivePort.sendPort.nativePort,
        _ptr.cast(),
        kind.value,
        capacity,
        parametersNative,
        parametersLen,
        payload != null ? payload.nativePtr.cast() : nullptr,
        encodingNative,
        encodingLen,
        schemaNative,
        schemaLen,
        attachment != null ? attachment.nativePtr.cast() : nullptr,
      );

      // The two PRE-MOVE codes are the exception to the unconditional mark, and
      // that is why they are kept distinguishable at the seam: on 10 and 11 the
      // shim returned before touching the payload or attachment, so marking
      // them would gravestone wrappers whose native handles are still the
      // caller's. On every other code the shim has either moved them into
      // zenoh-c or dropped them itself.
      if (rc != 10 && rc != 11) {
        if (payload != null) {
          payload.markConsumed();
        }
        if (attachment != null) {
          attachment.markConsumed();
        }
      }

      if (rc != 0) {
        if (rc == 10) {
          throw ArgumentError.value(
            capacity,
            'capacity',
            "must be non-negative and within this platform's size_t range",
          );
        }
        if (rc == 11) {
          throw ZenohException('Failed to allocate reply channel state', rc);
        }
        throw ZenohException('Querier get failed', rc);
      }
      teeValue = teeOut.value;
      started = true;
    } finally {
      if (parametersNative != nullptr) calloc.free(parametersNative);
      if (encodingNative != nullptr) calloc.free(encodingNative);
      if (schemaNative != nullptr) calloc.free(schemaNative);
      if (!started) {
        receivePort.close();
        calloc.free(handlerHandle);
      }
      calloc.free(teeOut);
    }

    return PullReplies(
      handlerHandle,
      teeValue,
      receivePort,
      kind,
      retainPayload,
    );
  }

  /// Sends a query via this querier and returns a stream of replies.
  ///
  /// Optional [parameters] are the selector's portion after `?`, carried
  /// **length-first** so an interior NUL is a value rather than a terminator.
  /// Omitting them and passing `''` are indistinguishable at the queryable —
  /// canon collapses the two before any wire encoding.
  /// Optional [payload] is consumed (ownership transferred to zenoh-c).
  /// Optional [encoding] specifies the payload encoding.
  /// Optional [attachment] is consumed (ownership transferred to zenoh-c).
  ///
  /// [payload], [encoding], and [attachment] are per-query options (they vary
  /// per [get] call), unlike the declaration-time options (target,
  /// consolidation, timeout) fixed at [Session.declareQuerier].
  ///
  /// ⚠️ **The returned stream is UNBOUNDED, and pausing it does not stop the
  /// flow.** Replies are pushed in as they arrive; `pause()` throttles
  /// delivery to your listener, not the responders.
  ///
  /// [pullGet] is the paced alternative — a bounded [PullReplies] handle you
  /// poll. It offers no `Stream` view; see [Session.get].
  ///
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
  ///
  /// Throws [StateError] if the querier has been closed.
  Stream<Reply> get({
    String? parameters,
    ZBytes? payload,
    Encoding? encoding,
    ZBytes? attachment,

    /// Whether each OK reply's sample carries a retained
    /// [Sample.payloadZBytes]. Off by default.
    ///
    /// ⚠️ This parse is INDEPENDENT of `Session.get`'s. A fix applied only
    /// there once left every `Querier` reply truncating, which is why this
    /// column carries two separate red legs rather than one.
    bool retainPayload = false,
  }) {
    if (_closed) throw StateError('Querier is closed');

    final controller = StreamController<Reply>();
    final receivePort = ReceivePort();
    final retention = ReplyRetention(enabled: retainPayload);

    receivePort.listen((dynamic message) {
      if (message == null) {
        // Null sentinel: query complete. The channel self-terminates here,
        // so this is where undelivered retained handles are released.
        retention.drain();
        receivePort.close();
        unawaited(controller.close());
      } else if (message is List) {
        final tag = message[0] as int;
        if (tag == 1) {
          // Ok reply: [1, keyexpr, payload_bytes, kind, attachment, encoding]
          // Length-carried key expression: an interior NUL survives, and the
          // decode is lenient like every other display string here.
          final keyExprStr = utf8.decode(
            message[1] as Uint8List,
            allowMalformed: true,
          );
          // ⛔ Same guard as the other three seams, and this file is the one
          // an earlier enumeration MISSED: it parses the reply post
          // independently of session.dart while sharing the C posting, so a
          // three-seam fix would have left this column silently broken.
          final payloadFailure = undecodableRc(message[2]);
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
          final payloadBytes = message[2] as Uint8List;
          final kind = message[3] as int;
          final attachmentBytes = message[4] as Uint8List?;
          // Length-carried like the key expression above; this parser is
          // independent of session.dart::_createReplyChannel and shares the C
          // posting with it, so it needs the same change.
          final encodingBytes = message.length > 5
              ? message[5] as Uint8List?
              : null;
          // Slice 4: QoS/timestamp metadata (length-guarded, defensive). This
          // parser is independent of session.dart::_createReplyChannel.
          final timestampBytes = message.length > 6
              ? message[6] as Uint8List?
              : null;
          final priorityRaw = message.length > 7 ? message[7] as int : null;
          final congestionRaw = message.length > 8 ? message[8] as int : null;
          final expressRaw = message.length > 9 ? message[9] as int : null;
          // Slice 5: replier id (constant array positions 10/11), length-guarded.
          final replierZid = message.length > 10
              ? message[10] as Uint8List?
              : null;
          final replierEid = message.length > 11 ? message[11] as int? : null;
          final replierId = (replierZid != null && replierEid != null)
              ? EntityGlobalId(ZenohId(replierZid), replierEid)
              : null;

          // Seed [10a] element 12: the retained payload handle image, or null
          // when this carrier did not opt in. Length-guarded like every
          // element above it.
          final retainedImage = message.length > 12
              ? message[12] as Uint8List?
              : null;
          final sample = Sample(
            keyExpr: keyExprStr,
            payload: utf8.decode(payloadBytes, allowMalformed: true),
            payloadBytes: payloadBytes,
            kind: kind == 0 ? SampleKind.put : SampleKind.delete,
            attachment: attachmentBytes != null
                ? utf8.decode(attachmentBytes, allowMalformed: true)
                : null,
            attachmentBytes: attachmentBytes,
            encoding: encodingBytes != null
                ? utf8.decode(encodingBytes, allowMalformed: true)
                : null,
            encodingBytes: encodingBytes,
            timestamp: timestampBytes != null
                ? Timestamp.fromRaw(timestampBytes)
                : null,
            // Wire priority is 1..7 -> Priority.fromWire.
            priority: priorityRaw != null
                ? Priority.fromWire(priorityRaw)
                : Priority.data,
            // Wire congestion is 0/1/2 -> CongestionControl.fromWire.
            congestionControl: congestionRaw != null
                ? CongestionControl.fromWire(congestionRaw)
                : CongestionControl.drop,
            express: expressRaw != null && (expressRaw != 0),
            payloadZBytes: ZBytes.fromPostedImage(retainedImage),
          );
          final reply = Reply.ok(sample, replierId: replierId);
          if (controller.isClosed) {
            // Drain branch: the channel already terminated and this was
            // still in the port queue, so nobody can receive it.
            retention.dropUndeliverable(reply);
            return;
          }
          retention.track(reply);
          controller.add(reply);
        } else if (tag == 0) {
          // Error reply: [0, error_payload_bytes, error_encoding]
          final errorFailure = undecodableRc(message[1]);
          if (errorFailure != null) {
            controller.addError(
              undecodableError('an error payload', errorFailure),
            );
            return;
          }
          final errorPayloadBytes = message[1] as Uint8List;
          final errorEncodingBytes = message.length > 2
              ? message[2] as Uint8List?
              : null;
          // Slice 5: replier id (constant array positions 3/4), length-guarded.
          final replierZid = message.length > 3
              ? message[3] as Uint8List?
              : null;
          final replierEid = message.length > 4 ? message[4] as int? : null;
          final replierId = (replierZid != null && replierEid != null)
              ? EntityGlobalId(ZenohId(replierZid), replierEid)
              : null;

          final replyError = ReplyError(
            payloadBytes: errorPayloadBytes,
            payload: utf8.decode(errorPayloadBytes, allowMalformed: true),
            encoding: errorEncodingBytes != null
                ? utf8.decode(errorEncodingBytes, allowMalformed: true)
                : null,
            encodingBytes: errorEncodingBytes,
          );
          controller.add(Reply.error(replyError, replierId: replierId));
        }
      }
    });

    // `started` gates the channel teardown in the finally -- the same F12
    // shape the ownership sweep found in Session.get, in its sibling. Every
    // throw between here and a successful zd_querier_get leaves a ReceivePort
    // that NO native sentinel can ever close, and an open port pins the
    // isolate alive. The reachable trigger is a disposed or already-consumed
    // payload/attachment: their nativePtr getters throw StateError partway
    // through building the call below.
    var started = false;
    // LENGTH-CARRIED, not NUL-terminated: same seam and same domain as
    // Session.get's parameters -- an interior NUL is a value here, not a
    // terminator.
    Pointer<Char> parametersNative = nullptr;
    var parametersLen = 0;
    // The encoding joins parameters on the length-carried side: two
    // INDEPENDENT channels, from the RAW pair (R-3a).
    Pointer<Char> encodingNative = nullptr;
    var encodingLen = 0;
    Pointer<Char> schemaNative = nullptr;
    var schemaLen = 0;

    try {
      final marshalled = allocLengthCarriedUtf8(parameters);
      parametersNative = marshalled.ptr;
      parametersLen = marshalled.len;
      final (mime, schema) = encoding != null
          ? encodingWireChannels(encoding)
          : (null, null);
      final encMarshalled = allocLengthCarriedUtf8(mime);
      encodingNative = encMarshalled.ptr;
      encodingLen = encMarshalled.len;
      final schemaMarshalled = allocLengthCarriedUtf8(schema);
      schemaNative = schemaMarshalled.ptr;
      schemaLen = schemaMarshalled.len;

      final rc = bindings.zd_querier_get(
        _ptr.cast(),
        parametersNative,
        parametersLen,
        receivePort.sendPort.nativePort,
        payload != null ? payload.nativePtr.cast() : nullptr,
        encodingNative,
        encodingLen,
        schemaNative,
        schemaLen,
        attachment != null ? attachment.nativePtr.cast() : nullptr,
        retainPayload ? 1 : 0,
      );

      // Mark payload + attachment ZBytes as consumed UNCONDITIONALLY: on
      // every return code zd_querier_get has either moved them into zenoh-c
      // or dropped them itself, so the caller must not touch them after this
      // call -- even on error. Marking before the rc-throw prevents a later
      // use-after-move.
      //
      // ⚠️ NOT because "every reachable error path here is post-move" -- the
      // comment this replaces claimed that and it was false. zd_querier_get's
      // context malloc fails PRE-move, and on that leg the unconditional mark
      // gravestoned a wrapper whose native handle nothing had released. The
      // shim's pre-move early-return now drops what it was handed, which is
      // what makes the unconditional mark true rather than approximately true.
      if (payload != null) {
        payload.markConsumed();
      }
      if (attachment != null) {
        attachment.markConsumed();
      }

      if (rc != 0) {
        throw ZenohException('Querier get failed', rc);
      }
      started = true;
    } finally {
      if (parametersNative != nullptr) calloc.free(parametersNative);
      if (encodingNative != nullptr) calloc.free(encodingNative);
      if (schemaNative != nullptr) calloc.free(schemaNative);
      if (!started) {
        receivePort.close();
        unawaited(controller.close());
      }
    }

    return retention.gate(controller.stream);
  }

  /// Returns whether any queryables currently match this querier's
  /// key expression.
  bool hasMatchingQueryables() {
    if (_closed) throw StateError('Querier has been closed');
    final matching = calloc<Int8>();
    try {
      final rc = bindings.zd_querier_get_matching_status(_ptr.cast(), matching);
      if (rc != 0) {
        throw ZenohException('Failed to get matching status', rc);
      }
      return matching.value != 0;
    } finally {
      calloc.free(matching);
    }
  }

  /// A stream of matching status changes, or null if the matching listener
  /// was not enabled when the querier was declared.
  /// ⚠️ **Unbounded, like every push stream here** — but this is an
  /// edge-signal channel, not a data channel: it carries transitions, not
  /// traffic, so there is deliberately no bounded form of it.
  ///
  Stream<bool>? get matchingStatus => _matchingController?.stream;

  /// Undeclares the querier and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_querier_drop(_ptr.cast());
    _matchingPort?.close();
    unawaited(_matchingController?.close());
    calloc.free(_ptr);
  }
}
