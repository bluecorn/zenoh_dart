import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';

/// A zenoh bytes writer for assembling raw byte payloads.
///
/// Wraps `z_owned_bytes_writer_t`. Call [finish] to produce a [ZBytes],
/// or [dispose] to release native resources without finishing.
///
/// This object holds a native handle, so it **cannot cross an isolate
/// boundary**: a copy would share this one's native address while carrying
/// its own fresh disposal flag, and the second release would be a
/// use-after-free. Sending it throws `ArgumentError` naming the class.
///
/// It carries a `NativeFinalizer` **safety net**: if it is dropped without an
/// explicit release, its native resources are reclaimed when the object is
/// collected.
/// ⛔ The net is **not a substitute** for releasing it explicitly — a finalizer
/// runs at an unpredictable time, or not at all if the program exits first.
class ZBytesWriter implements Finalizable {
  /// Creates an empty bytes writer.
  ZBytesWriter() : _ptr = _create() {
    // `_create` either returns a live slot or does not return, so reaching
    // here means the object exists and the net is safe to arm.
    bytesWriterFinalizer.attach(
      this,
      _ptr.cast(),
      detach: this,
      externalSize: bindings.zd_bytes_writer_sizeof(),
    );
  }

  final Pointer<Void> _ptr;
  bool _finished = false;
  bool _disposed = false;

  static Pointer<Void> _create() {
    final size = bindings.zd_bytes_writer_sizeof();
    final ptr = calloc.allocate<Void>(size);
    bindings.zd_bytes_writer_empty(ptr.cast());
    return ptr;
  }

  void _checkState() {
    if (_disposed) throw StateError('ZBytesWriter has been disposed');
    if (_finished) throw StateError('ZBytesWriter has been finished');
  }

  Pointer<Void> _loanMut() {
    final out = calloc<Pointer<Void>>();
    bindings.zd_bytes_writer_loan_mut(_ptr.cast(), out.cast());
    final loaned = out.value;
    calloc.free(out);
    return loaned;
  }

  /// Writes all bytes from [data] into the writer.
  ///
  /// Throws [StateError] if already finished or disposed.
  /// Throws [ZenohException] if the native write fails.
  void writeAll(Uint8List data) {
    _checkState();
    final nativeBuf = calloc.allocate<Uint8>(data.length);
    try {
      for (var i = 0; i < data.length; i++) {
        nativeBuf[i] = data[i];
      }
      final rc = bindings.zd_bytes_writer_write_all(
        _loanMut().cast(),
        nativeBuf,
        data.length,
      );
      if (rc != 0) throw ZenohException('Failed to write bytes', rc);
    } finally {
      calloc.free(nativeBuf);
    }
  }

  /// Appends owned [bytes] into the writer, consuming them.
  ///
  /// After this call, the [bytes] object is consumed and must not be used.
  ///
  /// Throws [StateError] if already finished or disposed.
  /// Throws [ZenohException] if the native append fails.
  void append(ZBytes bytes) {
    _checkState();
    final rc = bindings.zd_bytes_writer_append(
      _loanMut().cast(),
      bytes.nativePtr.cast(),
    );
    // markConsumed is unconditional and runs BEFORE the rc-throw: the shim
    // zd_bytes_writer_append z_bytes_move's the owned bytes, gravestoning the
    // native handle regardless of the return code. Marking before the throw
    // prevents a later use-after-move on any rc != 0 outcome, mirroring every
    // other send site (session.dart:250/302/844, query.dart:171).
    //
    // This ordering cannot be tested dynamically, and the rationale lives here
    // because that is the only place it can do any work. Every precondition
    // that could make the call return rc != 0 is intercepted earlier --
    // _checkState() (finished/disposed -> StateError) and bytes.nativePtr's
    // _ensureNotConsumed (consumed -> StateError) -- so no reachable public-API
    // path drives the error branch. Two tests once guarded this line; both
    // exercised only the success path and passed with or without the reorder,
    // so they were removed as dead weight (the success-path consume contract
    // remains pinned by bytes_writer_test's 'append consumes the ZBytes').
    // If you reorder these two statements, no test will tell you.
    bytes.markConsumed();
    if (rc != 0) throw ZenohException('Failed to append bytes', rc);
  }

  /// Finishes the writer and returns the produced [ZBytes].
  ///
  /// The writer is consumed by this call. After finishing,
  /// no further operations are allowed.
  ///
  /// Throws [StateError] if already finished or disposed.
  ZBytes finish() {
    _checkState();
    _finished = true;
    // ⛔ `finish()` IS A RELEASE PATH. It moves the handle into canon and frees
    // the slot below, so without this detach the net would later drop a moved
    // handle and free the slot a second time.
    bytesWriterFinalizer.detach(this);
    final bytesPtr = calloc.allocate<Void>(bindings.zd_bytes_sizeof());
    bindings.zd_bytes_writer_finish(_ptr.cast(), bytesPtr.cast());
    calloc.free(_ptr);
    return ZBytes.fromNative(bytesPtr);
  }

  /// Releases native resources held by this writer.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  /// Safe to call after [finish] -- no-op since resources were
  /// already transferred.
  ///
  /// Also **detaches this object's finalizer**, so the safety net cannot
  /// release it a second time.
  void dispose() {
    if (_disposed) return;
    if (_finished) {
      // `finish()` already detached and released; a second detach here would
      // be harmless but the early return makes it unreachable, and saying so
      // is what keeps the "safe to call multiple times" note honest.
      _disposed = true;
      return;
    }
    _disposed = true;
    bytesWriterFinalizer.detach(this);
    bindings.zd_bytes_writer_drop(_ptr.cast());
    calloc.free(_ptr);
  }
}
