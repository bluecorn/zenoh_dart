import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/session.dart' show Session;

/// A liveliness token that advertises the session's presence on a key
/// expression for as long as it remains undeclared.
///
/// Wraps `z_owned_liveliness_token_t`. Call [close] when done to undeclare
/// the token and release native resources.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// ⛔ **No `NativeFinalizer` is attached to this class**, deliberately: its
/// release is REMOTE-VISIBLE: an unretained token vanishing at garbage
/// collection sends a DELETE that intersecting liveliness subscribers observe,
/// which a working program does not expect.
/// Releasing it explicitly is therefore the only thing that reclaims it.
class LivelinessToken implements Finalizable {
  /// Declares a liveliness token on the given session and key expression.
  ///
  /// This is called internally by [Session.declareLivelinessToken].
  factory LivelinessToken.declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKeyExpr,
    String keyExpr,
  ) {
    final size = bindings.zd_liveliness_token_sizeof();
    final ptr = calloc<Uint8>(size);

    final rc = bindings.zd_liveliness_declare_token(
      ptr,
      loanedSession.cast(),
      loanedKeyExpr.cast(),
    );

    if (rc != 0) {
      calloc.free(ptr);
      throw ZenohException('Failed to declare liveliness token', rc);
    }

    return LivelinessToken._(ptr, keyExpr);
  }

  LivelinessToken._(this._ptr, this._keyExpr);

  final Pointer<Uint8> _ptr;
  final String _keyExpr;
  bool _closed = false;

  /// The key expression this liveliness token is declared on.
  String get keyExpr => _keyExpr;

  /// Undeclares the liveliness token and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_liveliness_token_drop(_ptr);
    calloc.free(_ptr);
  }
}
