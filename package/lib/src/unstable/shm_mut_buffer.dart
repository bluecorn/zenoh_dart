import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/unstable/shm_provider.dart' show ShmProvider;

/// A mutable shared memory buffer allocated from an [ShmProvider].
///
/// Wraps `z_owned_shm_mut_t`. Call [dispose] when done to release
/// native resources, unless the buffer has been consumed by [toBytes].
///
/// This object holds a native handle, so it CANNOT cross an isolate boundary.
///
/// It carries a `NativeFinalizer` safety net with TWO states. A fresh buffer's
/// finalizer releases the chunk and the slot. Once [toBytes] has moved the
/// chunk into a [ZBytes] that carries its own net, this one DOWNGRADES to
/// releasing the slot only — releasing the chunk here too would be a double
/// release.
///
/// ⚠️ **There used to be a third state, and it is worth knowing why it is
/// gone.** A `data` getter handed out a raw `Pointer<Uint8>` into the chunk.
/// A pointer already given away is an integer no guard can reach, so freeing
/// the chunk under it would have turned a leak into a use-after-free — and the
/// net had to downgrade on every read rather than arm. Since **every**
/// documented use of this class began by reading it, the net was, for the
/// producer path, structurally absent.
///
/// It was replaced by [write] and [read], which **copy**. Nothing escapes, so
/// CONV-6 clause (i) — *not reachable-in-use by construction … an escaped
/// pointer* — now holds by construction rather than by convention, and the
/// chunk-releasing net is armed unconditionally.
///
/// ⛔ The net is not a substitute for [dispose].
///
/// ## CONV-6, restated per clause for THIS class
///
/// The convention admits a `NativeFinalizer` only where three clauses hold.
/// They are re-checked here rather than inherited, because this unit changed
/// what the first one is being asked about.
///
/// 1. **Not reachable-in-use by construction.** ✅ **NOW HOLDS, and this is
///    what the unit changed.** The clause names *"an escaped pointer"* as a
///    disqualifier, and `data` was one — so the previous ruling, which
///    downgraded the net rather than arming it, was correct **on the surface
///    it was given**. This does not overturn that ruling; it removes the fact
///    the ruling was applied to. Nothing a caller holds in order to *use* this
///    buffer fails to reference it any more, because [write] and [read] copy
///    and hand back nothing that aliases the chunk.
/// 2. **Its native release calls no Dart C API.** ✅ Unchanged and re-checked:
///    the entry is `zd_shm_mut_drop` then `free`, neither of which reaches
///    `Dart_PostCObject_DL`.
/// 3. **Its release changes no other live Dart object's contract.** ✅
///    Unchanged and re-checked. A converted buffer moves its chunk into a
///    `ZBytes` carrying its own net, and that case is exactly what the
///    slot-only state exists for — so the one object whose contract could be
///    affected is the one this net stops releasing.
///
/// ⚠️ **The inherited condition is discharged, not waived.** The `[OWN]` seed
/// review required that *"the `ShmMutBuffer` finalizer lands with, or after,
/// S3's remedy"*. It lands **with** it, in the same slice.
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
class ShmMutBuffer implements Finalizable {
  /// Creates an ShmMutBuffer wrapping a native pointer.
  ///
  /// This is called internally by [ShmProvider.alloc].
  ///
  /// The pointer must address a heap-allocated `z_owned_shm_mut_t` that this
  /// package allocated. **The library never hands one out** — no member
  /// returns this address; [ShmProvider.alloc] passes the pointer it has
  /// just filled.
  ///
  /// ⛔ **A pointer this library did not produce aborts the VM.** It is
  /// stored and dereferenced without validation; nothing can reject a wrong
  /// one, so the process dies where an ordinary API would throw.
  ///
  /// ⚠️ **The crash need not arrive where the mistake was made.** This
  /// constructor arms the `NativeFinalizer` net unconditionally, so even a
  /// buffer that is never written and never disposed is released when it is
  /// collected — at a moment the collector picks, on a stack with nothing to
  /// do with the construction. A wrong pointer can therefore abort long
  /// after, and far from, the call that supplied it. (`Query` is the
  /// contrary case: it arms no net, so its abort arrives at first use
  /// instead.)
  ///
  /// Marked `@internal`, so naming it from another package draws a warning.
  /// ⛔ **A warning, not a fence**: [ShmMutBuffer] is exported by the
  /// unstable door and this is its only constructor, so the name still
  /// resolves.
  @internal
  ShmMutBuffer.fromNative(this._ptr) {
    shmMutFinalizer.attach(
      this,
      _ptr.cast(),
      detach: this,
      externalSize: bindings.zd_shm_mut_sizeof(),
    );
  }

  final Pointer<Void> _ptr;
  bool _disposed = false;
  bool _consumed = false;
  bool _slotOnly = false;

  /// Downgrades the net to the SLOT-ONLY state.
  ///
  /// ⚠️ **ONE caller, and that is the change.** It runs when the chunk stops
  /// being this wrapper's to free, which now happens on exactly one path:
  /// `toBytes()` moving the chunk into a [ZBytes] that has its own net. The
  /// second caller — the `data` getter's escape — is gone, and with it the
  /// reason a written-to buffer ever lost its chunk-releasing finalizer.
  ///
  /// Idempotent: it detaches BOTH shapes before attaching, so a second call
  /// cannot leave two free-block attachments on one slot (which would be a
  /// double free).
  void _downgradeToSlotOnly() {
    if (_slotOnly) return;
    _slotOnly = true;
    shmMutFinalizer.detach(this);
    freeBlockFinalizer
      ..detach(this)
      ..attach(
        this,
        _ptr.cast(),
        detach: this,
        externalSize: bindings.zd_shm_mut_sizeof(),
      );
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('ShmMutBuffer has been disposed');
    if (_consumed) throw StateError('ShmMutBuffer has been consumed');
  }

  /// Returns the length (in bytes) of this buffer.
  int get length {
    _ensureUsable();
    final loaned = bindings.zd_shm_mut_loan_mut(_ptr.cast());
    return bindings.zd_shm_mut_len(loaned);
  }

  /// The chunk as a typed view over its whole length.
  ///
  /// ⚠️ INTERNAL ONLY, and the reason matters. This view ALIASES the native
  /// chunk, and nothing in Dart can revoke a typed-data view once it has
  /// escaped -- a view handed to a caller would be the removed `data` getter
  /// wearing the costume of a Dart-owned list, which is strictly worse than
  /// the raw pointer was, because it does not look dangerous.
  ///
  /// ⛔ It must never be returned, stored in a field, or closed over.
  /// [write] copies INTO it; [read] returns `sublist`, which is already a
  /// copy. The distinction that makes `asTypedList` safe here is *does it
  /// leave the method*, not *is it used at all*.
  ///
  /// The caller must have passed `_ensureUsable()` first.
  Uint8List _view() {
    final loaned = bindings.zd_shm_mut_loan_mut(_ptr.cast());
    return bindings
        .zd_shm_mut_data_mut(loaned)
        .asTypedList(bindings.zd_shm_mut_len(loaned));
  }

  /// Copies [bytes] into this buffer, starting at [offset].
  ///
  /// The copying replacement for the removed `data` pointer. Because it
  /// copies, no reference to the chunk escapes and this buffer's safety net
  /// stays armed. Reading `data` used to downgrade that net to slot-only;
  /// nothing on this class does that any more except [toBytes], which has to.
  ///
  /// An empty [bytes] is a no-op, not a refusal -- zero is a legitimate
  /// length here. And nothing moves unless every check passes, so a refused
  /// write leaves the buffer exactly as it was.
  ///
  /// Throws an [ArgumentError] if [offset] is negative, or if any element of
  /// [bytes] lies outside `0..255`: a Dart `int` narrowing into a native
  /// `uint8_t` is domain-guarded Dart-side, because `Uint8List`'s own store
  /// semantics would otherwise mask the value down silently.
  /// Throws a [RangeError] if the write would end past the end of the
  /// buffer, and a [StateError] if the buffer has been disposed or consumed.
  void write(List<int> bytes, {int offset = 0}) {
    _ensureUsable();
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must be non-negative');
    }
    // The domain guard runs before any native call and before any byte
    // moves. A `Uint8List` source is in-domain by construction, so the
    // per-element scan is skipped for it: this is the SHM throughput path,
    // and a second full traversal of a multi-megabyte payload is not free.
    if (bytes is! Uint8List) {
      for (var i = 0; i < bytes.length; i++) {
        final value = bytes[i];
        if (value < 0 || value > 0xFF) {
          throw ArgumentError.value(
            value,
            'bytes[$i]',
            'must be a byte in the range 0..255',
          );
        }
      }
    }

    final view = _view();
    final end = offset + bytes.length;
    if (end > view.length) {
      throw RangeError.range(
        end,
        0,
        view.length,
        'offset + bytes.length',
        'a write must end inside the buffer',
      );
    }
    // Nothing native is allocated on this path -- the loan is a pointer
    // cast and the view borrows the chunk -- so there is no block to
    // release and no `finally` that would have to enclose the throws above.
    view.setRange(offset, end, bytes);
  }

  /// Returns a COPY of [length] bytes of this buffer, starting at [offset].
  ///
  /// ⛔ This **copies**, and is therefore deliberately NOT a no-copy read.
  /// It must not be read as delivering one: a no-copy read would have to
  /// hand back a view aliasing the chunk, which is the exact escape this
  /// pair exists to remove. The receive-side no-copy read is carved to a
  /// later unit.
  ///
  /// [length] defaults to everything from [offset] to the end of the buffer.
  /// A region that has never been written reads back as whatever the
  /// allocator left there; that is a real state, and it is returned
  /// verbatim rather than normalised.
  ///
  /// Throws an [ArgumentError] if [offset] or [length] is negative, a
  /// [RangeError] if the range would extend past the end of the buffer, and
  /// a [StateError] if the buffer has been disposed or consumed.
  Uint8List read({int offset = 0, int? length}) {
    _ensureUsable();
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must be non-negative');
    }
    if (length != null && length < 0) {
      throw ArgumentError.value(length, 'length', 'must be non-negative');
    }

    final view = _view();
    if (offset > view.length) {
      throw RangeError.range(
        offset,
        0,
        view.length,
        'offset',
        'a read must start inside the buffer',
      );
    }
    final end = offset + (length ?? view.length - offset);
    if (end > view.length) {
      throw RangeError.range(
        end,
        0,
        view.length,
        'offset + length',
        'a read must end inside the buffer',
      );
    }
    // `sublist` on a typed list COPIES. What leaves this method is a
    // Dart-owned list with no tie to the chunk.
    return view.sublist(offset, end);
  }

  /// Converts this SHM buffer into a [ZBytes] (zero-copy).
  ///
  /// This consumes the buffer -- subsequent operations will throw
  /// [StateError]. The caller owns the returned [ZBytes] and must
  /// call [ZBytes.dispose] when done.
  ///
  /// Throws [ZenohException] if the conversion fails.
  ZBytes toBytes() {
    _ensureUsable();
    final bytesPtr = calloc.allocate<Void>(bindings.zd_bytes_sizeof());
    final rc = bindings.zd_bytes_from_shm_mut(bytesPtr.cast(), _ptr.cast());

    // Marked consumed UNCONDITIONALLY, mirroring the ZBytes send sites. The
    // shim passes the handle as z_shm_mut_move(buf), so canon has gravestoned
    // it regardless of the return code; marking only on success left a
    // still-"usable" buffer over a moved handle, and dispose() would then have
    // dropped it a second time.
    //
    // ⚠️ NO RED LEG EXISTS for the failure branch and none is faked: the rc
    // comes from canon's z_bytes_from_shm_mut, which is not drivable to
    // failure through the public API at this pin. The success-path state tests
    // are what stay green; this comment is the record that the other branch is
    // reasoned, not exercised.
    _consumed = true;
    // The chunk has moved into the ZBytes, which carries its own net. What is
    // left here is the Dart slot, so the same downgrade applies.
    _downgradeToSlotOnly();

    if (rc != 0) {
      calloc.free(bytesPtr);
      throw ZenohException('Failed to convert ShmMutBuffer to ZBytes', rc);
    }
    return ZBytes.fromNative(bytesPtr);
  }

  /// Releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  /// If the buffer was consumed by [toBytes], only frees the calloc'd
  /// wrapper memory (the native SHM data is owned by the ZBytes).
  ///
  /// Also **detaches this object's finalizer**, so the safety net cannot
  /// release it a second time.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Both shapes, unconditionally: which one is attached depends on the
    // state, and detaching a key that was never attached is a no-op. A branch
    // here would be one more place for the three states to drift apart.
    shmMutFinalizer.detach(this);
    freeBlockFinalizer.detach(this);
    if (!_consumed) {
      bindings.zd_shm_mut_drop(_ptr.cast());
    }
    calloc.free(_ptr);
  }
}
