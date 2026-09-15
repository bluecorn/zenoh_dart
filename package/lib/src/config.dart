import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';

/// A Zenoh configuration.
///
/// Wraps `z_owned_config_t`. Use the default constructor for default
/// configuration, then call [insertJson5] to customise settings.
///
/// Must be [dispose]d when no longer needed to release native memory.
/// If passed to `Session.open`, the config is consumed and must not be
/// reused or disposed by the caller.
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
class Config implements Finalizable {
  /// Creates a default Zenoh configuration.
  ///
  /// Throws [ZenohException] if the native config creation fails.
  Config() : _ptr = calloc.allocate<Void>(bindings.zd_config_sizeof()) {
    final rc = bindings.zd_config_default(_ptr.cast());
    if (rc != 0) {
      calloc.free(_ptr);
      throw ZenohException('Failed to create default config', rc);
    }
    // AFTER the rc check, never before. A throw here has already freed the
    // block, and a finalizer attached to the half-built object would hand that
    // same address to `free()` again when it was collected.
    _attachNet();
  }

  /// Allocates a native config, populates it via [populate], and wraps the
  /// result. Shared skeleton for the F4 named constructors.
  ///
  /// [populate] receives the freshly-allocated (uninitialized) native config
  /// pointer and returns the shim return code (0 = success). On failure the
  /// native config is freed (no leak) and a [ZenohException] enriched with
  /// [errorContext] (plus upstream last-error detail where available) is
  /// thrown.
  factory Config._build(
    String errorContext,
    int Function(
      Pointer<Void> ptr,
      Pointer<Uint8> errBuf,
      int errCap,
      Pointer<Int> errLen,
    )
    populate,
  ) {
    final ptr = calloc.allocate<Void>(bindings.zd_config_sizeof());
    final result = _withDetailBuffer(
      (errBuf, errCap, errLen) => populate(ptr, errBuf, errCap, errLen),
    );
    if (result.rc != 0) {
      calloc.free(ptr);
      throw ZenohException.enriched(errorContext, result.rc, result.detail);
    }
    return Config._(ptr);
  }

  // Internal: wraps an already-populated native config pointer.
  //
  // `_build` reaches here only on success -- it frees and throws on a non-zero
  // rc without constructing -- so attaching in this body is the same
  // "attach only once the object exists" rule the default constructor follows.
  Config._(this._ptr) {
    _attachNet();
  }

  /// Creates a configuration from a JSON5 [json] string.
  ///
  /// The resulting config has the same lifecycle as a default [Config]: it may
  /// be passed to `Session.open` (which consumes it) or [dispose]d.
  ///
  /// Throws [ZenohException] (enriched with upstream detail where available)
  /// if [json] is not valid config JSON5.
  ///
  /// ⚠️ **The message may echo your config text.** On the `unstable` variant
  /// it carries canon's own words for the failure, and canon's json5 parser
  /// echoes the offending value **and the surrounding source line** — adjacent
  /// intact secrets included — with a caret pointing at the offending token.
  /// **Do not forward this message into a log, a crash report or a bug
  /// report** without deciding redaction first. No redaction is applied here;
  /// see [ZenohException.enriched] for why a general one is not implementable
  /// at this seam. On the default `stable` variant no upstream detail is
  /// carried at all, so the message is the base text alone.
  ///
  factory Config.fromStr(String json) {
    final nativeJson = json.toNativeUtf8();
    try {
      return Config._build(
        'Failed to create config from string',
        (ptr, errBuf, errCap, errLen) => bindings.zd_config_from_str(
          ptr.cast(),
          nativeJson.cast(),
          errBuf,
          errCap,
          errLen,
        ),
      );
    } finally {
      malloc.free(nativeJson);
    }
  }

  /// Creates a configuration from a JSON5 file at [path].
  ///
  /// The resulting config has the same lifecycle as a default [Config]: it may
  /// be passed to `Session.open` (which consumes it) or [dispose]d.
  ///
  /// Throws [ZenohException] (enriched with upstream detail where available)
  /// if [path] cannot be read or does not contain valid config JSON5.
  ///
  /// The `_from_file_substr` substring variant is carved (equivalent-by-design
  /// to this null-terminated form); not bound.
  ///
  /// ⚠️ **The message may echo your config text.** On the `unstable` variant
  /// it carries canon's own words for the failure, and canon's json5 parser
  /// echoes the offending value **and the surrounding source line** — adjacent
  /// intact secrets included — with a caret pointing at the offending token.
  /// **Do not forward this message into a log, a crash report or a bug
  /// report** without deciding redaction first. No redaction is applied here;
  /// see [ZenohException.enriched] for why a general one is not implementable
  /// at this seam. On the default `stable` variant no upstream detail is
  /// carried at all, so the message is the base text alone.
  ///
  factory Config.fromFile(String path) {
    final nativePath = path.toNativeUtf8();
    try {
      return Config._build(
        'Failed to create config from file "$path"',
        (ptr, errBuf, errCap, errLen) => bindings.zd_config_from_file(
          ptr.cast(),
          nativePath.cast(),
          errBuf,
          errCap,
          errLen,
        ),
      );
    } finally {
      malloc.free(nativePath);
    }
  }

  /// Creates a configuration from the `ZENOH_CONFIG` environment variable.
  ///
  /// The resulting config has the same lifecycle as a default [Config]: it may
  /// be passed to `Session.open` (which consumes it) or [dispose]d.
  ///
  /// Throws [ZenohException] (enriched with upstream detail where available)
  /// if `ZENOH_CONFIG` is unset or points at a missing/malformed config.
  ///
  /// ⚠️ **The message may echo your config text.** On the `unstable` variant
  /// it carries canon's own words for the failure, and canon's json5 parser
  /// echoes the offending value **and the surrounding source line** — adjacent
  /// intact secrets included — with a caret pointing at the offending token.
  /// **Do not forward this message into a log, a crash report or a bug
  /// report** without deciding redaction first. No redaction is applied here;
  /// see [ZenohException.enriched] for why a general one is not implementable
  /// at this seam. On the default `stable` variant no upstream detail is
  /// carried at all, so the message is the base text alone.
  ///
  factory Config.fromEnv() {
    return Config._build(
      'Failed to create config from environment',
      (ptr, errBuf, errCap, errLen) =>
          bindings.zd_config_from_env(ptr.cast(), errBuf, errCap, errLen),
    );
  }

  /// Attaches the safety net.
  ///
  /// `detach: this` is the key: ONE `detach(this)` on any release path
  /// reverses it, so the explicit paths and the finalizer are mutually
  /// exclusive by construction rather than by a flag.
  void _attachNet() {
    configFinalizer.attach(
      this,
      _ptr.cast(),
      detach: this,
      externalSize: bindings.zd_config_sizeof(),
    );
  }

  final Pointer<Void> _ptr;
  bool _disposed = false;

  // Internal: set by Session.open after consuming the config.
  bool _consumed = false;

  /// Inserts a JSON5 value at the given configuration key path.
  ///
  /// JSON5 string values require inner quotes, e.g.:
  /// ```dart
  /// config.insertJson5('mode', '"peer"');
  /// ```
  ///
  /// Throws [ZenohException] if the key is invalid or the value is rejected.
  /// Throws [StateError] if the config has been disposed or consumed.
  ///
  /// ⚠️ **The message may echo your config text.** On the `unstable` variant
  /// it carries canon's own words for the failure, and canon's json5 parser
  /// echoes the offending value **and the surrounding source line** — adjacent
  /// intact secrets included — with a caret pointing at the offending token.
  /// **Do not forward this message into a log, a crash report or a bug
  /// report** without deciding redaction first. No redaction is applied here;
  /// see [ZenohException.enriched] for why a general one is not implementable
  /// at this seam. On the default `stable` variant no upstream detail is
  /// carried at all, so the message is the base text alone.
  ///
  /// ⛔ This is the site where the echo is widest: the value you passed is
  /// exactly what canon is complaining about, so it is exactly what comes
  /// back.
  void insertJson5(String key, String value) {
    _ensureNotDisposed();
    _ensureNotConsumed();
    final nativeKey = key.toNativeUtf8();
    final nativeValue = value.toNativeUtf8();
    try {
      final result = _withDetailBuffer(
        (errBuf, errCap, errLen) => bindings.zd_config_insert_json5(
          _ptr.cast(),
          nativeKey.cast(),
          nativeValue.cast(),
          errBuf,
          errCap,
          errLen,
        ),
      );
      if (result.rc != 0) {
        // Detail-carrying site: the message canon produced for THIS call
        // came back from the call itself, in storage this frame supplied.
        throw ZenohException.enriched(
          'Failed to insert config value for key "$key"',
          result.rc,
          result.detail,
        );
      }
    } finally {
      malloc
        ..free(nativeKey)
        ..free(nativeValue);
    }
  }

  /// Returns the JSON value at [key].
  ///
  /// Throws [ZenohException] (enriched with upstream detail where available)
  /// if the key is absent or invalid (rc-checked).
  /// Throws [StateError] if the config has been disposed or consumed.
  ///
  /// ⚠️ **The message may echo your config text.** On the `unstable` variant
  /// it carries canon's own words for the failure, and canon's json5 parser
  /// echoes the offending value **and the surrounding source line** — adjacent
  /// intact secrets included — with a caret pointing at the offending token.
  /// **Do not forward this message into a log, a crash report or a bug
  /// report** without deciding redaction first. No redaction is applied here;
  /// see [ZenohException.enriched] for why a general one is not implementable
  /// at this seam. On the default `stable` variant no upstream detail is
  /// carried at all, so the message is the base text alone.
  ///
  String get(String key) {
    _ensureNotDisposed();
    _ensureNotConsumed();
    final nativeKey = key.toNativeUtf8();
    final ownedStr = calloc.allocate<Void>(bindings.zd_string_sizeof());
    try {
      final result = _withDetailBuffer(
        (errBuf, errCap, errLen) => bindings.zd_config_get(
          _ptr.cast(),
          nativeKey.cast(),
          ownedStr.cast(),
          errBuf,
          errCap,
          errLen,
        ),
      );
      if (result.rc != 0) {
        throw ZenohException.enriched(
          'Failed to get config key "$key"',
          result.rc,
          result.detail,
        );
      }
      final loanedStr = bindings.zd_string_loan(ownedStr.cast());
      final data = bindings.zd_string_data(loanedStr);
      final len = bindings.zd_string_len(loanedStr);
      return data.cast<Utf8>().toDartString(length: len);
    } finally {
      bindings.zd_string_drop(ownedStr.cast());
      calloc.free(ownedStr);
      malloc.free(nativeKey);
    }
  }

  /// Returns this configuration as a JSON string.
  ///
  /// This overrides [Object.toString], which by Dart convention must not throw
  /// (it is called implicitly during interpolation/print). It returns the
  /// serialized JSON for a live config, and a placeholder for the disposed or
  /// consumed edge (the plan is silent on that edge; placeholder is a
  /// Dart-convention decision).
  @override
  String toString() {
    if (_disposed || _consumed) return 'Config(unavailable)';
    final ownedStr = calloc.allocate<Void>(bindings.zd_string_sizeof());
    try {
      final rc = bindings.zd_config_to_string(_ptr.cast(), ownedStr.cast());
      if (rc != 0) return 'Config(error: $rc)'; // toString must not throw
      final loanedStr = bindings.zd_string_loan(ownedStr.cast());
      final data = bindings.zd_string_data(loanedStr);
      final len = bindings.zd_string_len(loanedStr);
      return data.cast<Utf8>().toDartString(length: len);
    } finally {
      bindings.zd_string_drop(ownedStr.cast());
      calloc.free(ownedStr);
    }
  }

  /// Releases native resources held by this configuration.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  ///
  /// Also **detaches this object's finalizer**, so the safety net cannot
  /// release it a second time.
  ///
  /// Throws [StateError] if the config has been consumed by `Session.open` or
  /// `Zenoh.scout`. This asymmetry with `ZBytes.dispose` (which no-ops on a
  /// consumed payload) is deliberate and pinned by test: disposing a config
  /// you already handed to the session is a caller bug worth reporting, and a
  /// config is consumed once per session rather than once per message. The
  /// consumed config's memory is already fully released by [markConsumed], so
  /// this throw costs nothing.
  void dispose() {
    if (_disposed) return;
    _ensureNotConsumed();
    _disposed = true;
    // Detach BEFORE releasing, and after the guard above: a dispose that
    // throws because the config was consumed must not take the net down, and
    // on that path `markConsumed` has already detached anyway.
    configFinalizer.detach(this);
    bindings.zd_config_drop(_ptr.cast());
    calloc.free(_ptr);
  }

  /// Internal: returns the native pointer for use by Session.open.
  Pointer<Void> get nativePtr {
    _ensureNotDisposed();
    _ensureNotConsumed();
    return _ptr;
  }

  /// Internal: called by `Session.open` / `Zenoh.scout` after the config has
  /// been moved into zenoh-c via `z_config_move`.
  ///
  /// Mirrors `ZBytes.markConsumed`: the move gravestones the native
  /// `z_owned_config_t`, so the Dart-owned calloc block wrapping it is freed
  /// here. The native handle is deliberately NOT dropped (zenoh-c already
  /// gravestoned it -- drop-after-move is the double-drop class).
  ///
  /// Unlike `ZBytes`, a consumed config is not silently disposable: [dispose]
  /// still throws [StateError] (see its doc). Freeing here is what makes the
  /// internally-created config of a `Session.open({config: null})` reclaimable
  /// at all -- it has no other owner to dispose it.
  ///
  /// Callers must mark only *after* the consuming FFI call has returned.
  void markConsumed() {
    if (_disposed || _consumed) return;
    _consumed = true;
    // ⛔ THE HOT DETACH. This method FREES the block rather than transferring
    // it, so without this line the finalizer would later hand the same address
    // to `free()` a second time -- a double free on the session-open path, not
    // a leak. Canon has already gravestoned the native handle, so the
    // finalizer's `zd_config_drop` would be a drop-after-move besides.
    configFinalizer.detach(this);
    calloc.free(_ptr);
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('Config has been disposed');
  }

  void _ensureNotConsumed() {
    if (_consumed) throw StateError('Config has been consumed by Session.open');
  }
}

/// The rc a detail-carrying shim call returned, and canon's own words for it.
typedef _DetailedCall = ({int rc, String? detail});

/// Mirrors `ZD_LAST_ERROR_CAP` in `src/zenoh_dart.h`.
///
/// The shim clamps to `ZD_LAST_ERROR_CAP - 1` whatever capacity it is handed,
/// so passing exactly this receives everything the shim will ever give and a
/// larger buffer would buy nothing. A drift here costs detail, never safety:
/// the shim never writes past the capacity it is told.
const int _detailCap = 512;

/// Runs [call] with detail storage **this call owns**, and returns both what
/// it returned and what it wrote.
///
/// ⛔ This is the whole mechanism, so it is worth stating plainly: the buffer
/// is allocated here, handed to exactly one call, read once, and freed before
/// this function returns. No other call can see it and it does not survive to
/// be read later — which is what makes a foreign detail unrepresentable rather
/// than merely unlikely. See [ZenohException.enriched] for what the previous
/// shape was and what it measured.
///
/// Allocate-last / outer-finally: both blocks are allocated after every
/// validation the caller could throw on, and the `finally` encloses every
/// statement that can throw, [call] included.
_DetailedCall _withDetailBuffer(
  int Function(Pointer<Uint8> errBuf, int errCap, Pointer<Int> errLen) call,
) {
  final errBuf = calloc<Uint8>(_detailCap);
  final errLen = calloc<Int>();
  try {
    final rc = call(errBuf, _detailCap, errLen);
    final n = errLen.value;
    if (n <= 0) return (rc: rc, detail: null);
    // Lenient by design: stage 4 of the truncation chain. The shim's clamp can
    // cut a multi-byte sequence, and a message that arrives as U+FFFD is
    // strictly better than a decode that throws while reporting an error.
    return (
      rc: rc,
      detail: utf8.decode(errBuf.asTypedList(n), allowMalformed: true),
    );
  } finally {
    calloc
      ..free(errBuf)
      ..free(errLen);
  }
}
