import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/finalizers.dart';
import 'package:zenoh_dart/src/native_lib.dart';

/// Runs [action] with a loaned key expression obtained from [keyExpr].
///
/// [keyExpr] must be a `String` or a [KeyExpr] — the union every key
/// expression parameter in this package accepts. A `String` is validated into
/// a temporary [KeyExpr] that is disposed in a `finally`; a [KeyExpr] is
/// loaned directly and **never** disposed, because it belongs to the caller.
///
/// The type check runs before any allocation, so a wrong-typed argument
/// cannot strand native memory.
///
/// This is the session-free half of the seam: the reply path has no session
/// handle. `Session` wraps it to add the session loan.
@internal
T withLoanedKeyExpr<T>(
  Object keyExpr,
  String paramName,
  T Function(Pointer<Void> loanedKe) action,
) {
  if (keyExpr is KeyExpr) {
    return action(keyExpr.loanedKeyExpr);
  }
  if (keyExpr is String) {
    final temp = KeyExpr(keyExpr);
    try {
      return action(temp.loanedKeyExpr);
    } finally {
      temp.dispose();
    }
  }
  throw ArgumentError.value(
    keyExpr,
    paramName,
    'must be a String or a KeyExpr',
  );
}

/// The string form of a union key expression argument.
///
/// Several declared entities still expose their key expression as a Dart
/// `String`; when the argument arrives as a [KeyExpr] the declaration records
/// its value. Retyping those getters is a later, breaking change.
@internal
String keyExprString(Object keyExpr, String paramName) {
  if (keyExpr is KeyExpr) return keyExpr.value;
  if (keyExpr is String) return keyExpr;
  throw ArgumentError.value(
    keyExpr,
    paramName,
    'must be a String or a KeyExpr',
  );
}

/// A Zenoh key expression.
///
/// One type, two native backings:
///
/// * a **view** backing (`z_view_keyexpr_t`), produced by the constructor,
///   which borrows a native buffer this object allocates and releases; and
/// * an **owned** backing (`z_owned_keyexpr_t`), produced by
///   `Session.declareKeyExpr`.
///
/// Both loan to the same `z_loaned_keyexpr_t`, which is why every operation
/// takes one and the same handle regardless of where the key expression came
/// from — a declared key expression is not a separate type and needs no
/// separate method.
///
/// ### The key expression domain, and where this binding is byte-exact
///
/// The grammar forbids `//`, a leading or trailing `/`, and the characters
/// `?`, `#` and `$` (outside `$*`). It does **not** forbid an interior NUL,
/// and canon accepts one: a key expression whose UTF-8 bytes are
/// `[97, 0, 98]` is a real key expression. It is carried byte-exact through
/// construction, declaration, [concat], [join] and [clone], and zenoh carries
/// it across the wire byte-exact too.
///
/// **The whole round trip is byte-exact.** Every receive surface — a
/// subscriber's `Sample.keyExpr`, a queryable's `Query.keyExpr`, a reply
/// sample's key expression at either a getter or a `Querier`, and
/// `PullSubscriber.tryRecv` — carries the key expression length-carried
/// rather than as a C string, so an interior NUL survives delivery as well as
/// sending.
///
/// ⚠️ **Non-ASCII key expressions are unusable with zenoh 1.8.0**, and this is
/// upstream, not a limit of this binding. A `KeyExpr` built from CJK, accented
/// Latin or emoji text constructs and round-trips correctly here — but passing
/// one to any session operation (`put`, `declareSubscriber`,
/// `Session.declareKeyExpr`, …) **panics inside zenoh's routing layer and
/// aborts the process**, at
/// `zenoh/src/net/routing/dispatcher/resource.rs` (`byte index N is not a
/// char boundary`). Keep key expressions ASCII until that is fixed upstream.
///
/// ### Canon form, and the two construction doors
///
/// A key expression is in **canon form** when its wildcards are spelled the
/// one way zenoh treats as normal. `hello/**/**` and `hello/**` denote the
/// same set of keys, but only the second is canon — every set of equivalent
/// spellings has exactly one canon member.
///
/// There are two doors, and the strict one is the default:
///
/// * [KeyExpr.new] — **strict**. It rejects a non-canon expression rather
///   than quietly rewriting it, so the expression you passed is the one you
///   get. Use it when a difference between what you wrote and what zenoh
///   would use should be an error rather than a silent correction.
/// * [KeyExpr.autocanonize] — the additive door. It rewrites the expression
///   into canon form and constructs from the result. Use it when the input
///   comes from somewhere you do not control.
///
/// Beside them, [isCanon] answers the question without constructing anything
/// or throwing, and [canonize] performs the rewrite as a pure `String`
/// transform — its documentation states the four rewrite rules with worked
/// examples, since zenoh's own documentation states them nowhere.
///
/// ⚠️ **All four entry points judge the bytes, not the Dart `String`.** A
/// Dart string may hold a lone surrogate, and `utf8.encode` substitutes
/// U+FFFD for it *before* zenoh sees a byte. So `KeyExpr('a\uD800b').value`
/// reads back `'a�b'`, and `canonize` and `autocanonize` return the
/// substituted form too. The round trip is byte-exact, which on that one
/// input class is not the same thing as `String`-identical.
///
/// Must be [dispose]d when no longer needed to release native memory. For a
/// declared key expression, [dispose] is the **local** release: it frees this
/// handle and unregisters nothing. `Session.undeclareKeyExpr` is the
/// remote-visible act, and it consumes the handle.
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
class KeyExpr implements Finalizable {
  /// Creates a [KeyExpr] from the given key expression string.
  ///
  /// The expression crosses to native as a pointer and a **byte length**, so
  /// the full key expression domain survives construction byte-exact --
  /// including an interior NUL, which the grammar permits and canon accepts.
  ///
  /// **This door is strict.** It rejects an expression that is merely not in
  /// canon form (`a/**/**/c`) just as firmly as one that is invalid (`a//b`),
  /// rather than rewriting it — so what you passed is what you get. For the
  /// door that constructs *through* the rewrite, see [KeyExpr.autocanonize];
  /// to ask the question without constructing anything, see [isCanon].
  ///
  /// ⚠️ [expr] is judged as **bytes**. A lone surrogate in the Dart string is
  /// replaced with U+FFFD by `utf8.encode` before zenoh sees anything, so
  /// [value] reads back the substituted form rather than the input string.
  ///
  /// Throws [ZenohException] if [expr] is not a valid key expression
  /// (e.g., empty string).
  KeyExpr(String expr) : this._encoded(expr, utf8.encode(expr));

  KeyExpr._encoded(String expr, Uint8List encoded)
    : _kePtr = calloc.allocate<Void>(bindings.zd_view_keyexpr_sizeof()),
      _nativeStr = _copyToNative(encoded),
      _isOwned = false {
    final rc = bindings.zd_view_keyexpr_from_substr(
      _kePtr.cast(),
      _nativeStr.cast(),
      encoded.length,
    );
    if (rc != 0) {
      malloc.free(_nativeStr);
      calloc.free(_kePtr);
      throw ZenohException('Invalid key expression: "$expr"', rc);
    }
    // AFTER the rc check: a throw here has already freed both blocks, and a
    // finalizer attached to the half-built object would hand those same
    // addresses to `free()` again.
    _attachViewNet(encoded.length + 1);
  }

  /// Creates a [KeyExpr] from [expr], **canonizing it first**.
  ///
  /// The additive door beside the strict default. Where `KeyExpr(expr)`
  /// rejects a non-canon expression, this rewrites it into canon form and
  /// constructs from the result — so `KeyExpr.autocanonize('a/**/**/c')` is
  /// the key expression `a/**/c`, and its [value] reads back the canonized
  /// form, not the input. See [canonize] for the four rewrite rules.
  ///
  /// Canonize-then-validate, exactly as canon composes it: an expression that
  /// is still invalid after the rewrite throws [ZenohException] carrying
  /// canon's code — the same exception the strict constructor throws, for the
  /// same inputs.
  ///
  /// The result is an **ordinary [KeyExpr]** in every respect: it delivers,
  /// answers [intersects]/[includes]/[equals], [clone]s and [dispose]s
  /// identically to one built any other way, and nothing on it reports
  /// whether canonization actually happened — canon carries no such signal.
  ///
  /// Canonization is construction-and-validation only, so **non-ASCII input
  /// is safe here** — but the resulting handle is not safe to *use*: see the
  /// non-ASCII warning in this class's documentation. [expr] is judged as
  /// bytes, with the encode-boundary caveat described there.
  ///
  /// The caller must [dispose] the result.
  factory KeyExpr.autocanonize(String expr) {
    final encoded = utf8.encode(expr);
    // Canon COPIES this before canonizing — the buffer is `const` on its side
    // and is never written — so unlike `canonize` there is no in-place
    // rewrite here. It must still be non-NULL at length 0.
    final exprPtr = _copyToNative(encoded);
    // Canon writes the canonized length back; nothing below reads it, because
    // the owned key expression carries its own bytes. The cell exists because
    // canon's signature takes one, and it is released either way.
    final lenCell = calloc<Size>();
    // Allocate-last: the slot is the final block taken, after everything that
    // could have thrown, and it is freed on the rc-failure path.
    final slot = calloc.allocate<Void>(bindings.zd_keyexpr_sizeof());
    try {
      lenCell.value = encoded.length;
      final rc = bindings.zd_keyexpr_from_substr_autocanonize(
        slot.cast(),
        exprPtr.cast(),
        lenCell,
      );
      if (rc != 0) {
        calloc.free(slot);
        throw ZenohException('Invalid key expression: "$expr"', rc);
      }
      return KeyExpr._owned(slot);
    } finally {
      malloc.free(exprPtr);
      calloc.free(lenCell);
    }
  }

  /// @nodoc
  ///
  /// Internal: declares [loanedKe] on [loanedSession] and wraps the result.
  ///
  /// Lives here rather than in `Session` so that every `z_owned_keyexpr_t`
  /// slot is allocated, checked and released by the type that owns the
  /// backing. The out-param is written on every path — canon writes a
  /// gravestone on failure — so the return code is checked *before* anything
  /// wraps it: a gravestone reads back as the literal `dummy`, which is a
  /// plausible-looking string that is not the caller's key expression.
  @internal
  factory KeyExpr.declareOn(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKe,
  ) {
    final slot = calloc.allocate<Void>(bindings.zd_keyexpr_sizeof());
    final rc = bindings.zd_declare_keyexpr(
      loanedSession.cast(),
      slot.cast(),
      loanedKe.cast(),
    );
    if (rc != 0) {
      calloc.free(slot);
      throw ZenohException('Failed to declare key expression', rc);
    }
    return KeyExpr._owned(slot);
  }

  /// Wraps a `z_owned_keyexpr_t` slot canon has already filled successfully.
  KeyExpr._owned(this._kePtr) : _nativeStr = nullptr, _isOwned = true {
    _attachOwnedNet();
  }

  /// Copies [bytes] into a freshly `malloc`'d native buffer.
  ///
  /// A trailing NUL is appended as hygiene only -- nothing reads this buffer
  /// as a C string, because the length is what crosses the seam.
  static Pointer<Utf8> _copyToNative(Uint8List bytes) {
    final p = malloc<Uint8>(bytes.length + 1);
    p.asTypedList(bytes.length).setAll(0, bytes);
    p[bytes.length] = 0;
    return p.cast<Utf8>();
  }

  /// Reports whether [keyExpr] is a valid key expression in **canon form**.
  ///
  /// **Total: this never throws, on any input.** It is the predicate to reach
  /// for instead of constructing and catching — a `bool` answer costs no
  /// allocation and no exception as control flow.
  ///
  /// ⚠️ `false` means *"not a canon key expression"* and nothing finer. It
  /// covers both an **invalid** expression (`a//b`, `a?b`, the empty string)
  /// and a merely **non-canon** one (`a/**/**/c`, which [canonize] rewrites
  /// to `a/**/c`). Canon itself does not discriminate the two — it returns
  /// the same code for both — so neither does this, rather than invent a
  /// distinction the contract is not carrying. To tell them apart, ask
  /// [canonize]: it succeeds on the second class and throws on the first.
  ///
  /// `isCanon(s)` is `true` exactly when `KeyExpr(s)` constructs.
  ///
  /// Validation only — nothing is constructed and nothing is sent — so
  /// **non-ASCII input is safe here**, unlike a key expression handed to a
  /// session operation (see the non-ASCII warning in this class's
  /// documentation). [keyExpr] is judged as bytes, with the encode-boundary
  /// caveat described there.
  static bool isCanon(String keyExpr) {
    final encoded = utf8.encode(keyExpr);
    // Never NULL, even for the empty string: canon builds a Rust slice from
    // this pointer, slice::from_raw_parts(NULL, 0) is undefined behaviour,
    // and this is the ONE entry in the canonization family canon does not
    // NULL-guard itself. `_copyToNative` mallocs `len + 1`, so the pointer is
    // valid at length 0 too.
    final exprPtr = _copyToNative(encoded);
    try {
      return bindings.zd_keyexpr_is_canon(exprPtr.cast(), encoded.length) == 0;
    } finally {
      malloc.free(exprPtr);
    }
  }

  /// Returns [keyExpr] rewritten into **canon form**.
  ///
  /// A pure transform: no handle, no native resource, no lifecycle. On input
  /// that is already canon it returns the same bytes back, unchanged.
  ///
  /// The rewrite is canon's, and it is these four rules:
  ///
  /// * a run of contiguous `$*` collapses to one — `hello/foo$*$*/bar`
  ///   becomes `hello/foo$*/bar`;
  /// * contiguous `**` chunks collapse to one — `hello/**/**` becomes
  ///   `hello/**`;
  /// * a chunk that is exactly `$*` becomes `*` — `hello/$*/bye` becomes
  ///   `hello/*/bye`;
  /// * `**/*` reorders to `*/**` — `hello/**/*` becomes `hello/*/**`.
  ///
  /// **Throws [ZenohException] only on genuine invalidity** — an expression
  /// canon rejects even after the rewrite, such as `a//b` or the empty
  /// string. It never throws on a merely non-canon expression: rewriting
  /// those is the whole point of the method, and they are exactly the inputs
  /// the strict [KeyExpr] constructor turns away.
  ///
  /// `KeyExpr(KeyExpr.canonize(s))` therefore constructs for every `s` this
  /// returns, and canonizing twice returns the same bytes as canonizing once.
  ///
  /// A `String`-to-`String` transform — nothing is constructed and nothing is
  /// sent — so **non-ASCII input is safe here**, and the rewrite operates on
  /// `/`-delimited chunks and ASCII metacharacters, never splitting a
  /// multi-byte character. Using the *result* with a session is a different
  /// question: see the non-ASCII warning in this class's documentation.
  /// [keyExpr] is transformed as bytes, with the encode-boundary caveat
  /// described there.
  static String canonize(String keyExpr) {
    final encoded = utf8.encode(keyExpr);
    // 🔴 Canon rewrites this buffer IN PLACE through a `&mut str`. It is the
    // marshalling layer's own malloc'd process-heap block -- never
    // Dart-managed memory, never a string literal, never read-only -- which
    // is the whole of the SEGFAULT guard, and it is non-NULL at length 0.
    final buf = _copyToNative(encoded);
    // Canon writes the canonized length back here, on success only. It is the
    // ONLY truth about the result's extent: the rewrite can preserve the
    // length as easily as shorten it, so nothing below reuses `encoded`'s.
    final lenCell = calloc<Size>();
    try {
      lenCell.value = encoded.length;
      final rc = bindings.zd_keyexpr_canonize(buf.cast(), lenCell);
      if (rc != 0) {
        throw ZenohException('Invalid key expression: "$keyExpr"', rc);
      }
      return buf.cast<Utf8>().toDartString(length: lenCell.value);
    } finally {
      malloc.free(buf);
      calloc.free(lenCell);
    }
  }

  /// Attaches the net for a VIEW backing: TWO blocks, TWO attachments, ONE key.
  ///
  /// A view-backed key expression holds a `calloc`'d `z_view_keyexpr_t` slot
  /// AND the `malloc`'d string it borrows. One token cannot reach both, and the
  /// answer is not a shim-side token struct — that would cost a `malloc` per
  /// wrapper object. Two attachments under one detach key cost nothing extra,
  /// and one `detach(this)` reverses both.
  ///
  /// ⚠️ Both use the FREE-ONLY entry, deliberately: a view owns nothing, so
  /// there is no canon handle to drop. Routing it onto the owned entry would
  /// drop a handle that was never owned.
  ///
  /// [strBytes] is the exact allocated length (`utf8` bytes + the NUL
  /// `_copyToNative` writes) — the one `externalSize` in this seed that is both
  /// exact and free.
  void _attachViewNet(int strBytes) {
    freeBlockFinalizer
      ..attach(
        this,
        _kePtr.cast(),
        detach: this,
        externalSize: bindings.zd_view_keyexpr_sizeof(),
      )
      ..attach(
        this,
        _nativeStr.cast(),
        detach: this,
        externalSize: strBytes,
      );
  }

  /// Attaches the net for an OWNED backing: one block, one attachment.
  void _attachOwnedNet() {
    keyExprFinalizer.attach(
      this,
      _kePtr.cast(),
      detach: this,
      externalSize: bindings.zd_keyexpr_sizeof(),
    );
  }

  /// Takes the net down, whichever backing this is.
  ///
  /// Both are called unconditionally rather than branching on [_isOwned]:
  /// detaching a key that was never attached to that finalizer is a no-op, and
  /// a branch here would be one more place for the two shapes to drift apart.
  void _detachNet() {
    keyExprFinalizer.detach(this);
    freeBlockFinalizer.detach(this);
  }

  final Pointer<Void> _kePtr;
  final Pointer<Utf8> _nativeStr;
  final bool _isOwned;
  bool _disposed = false;
  bool _undeclared = false;

  /// Internal: returns the native pointer for use by Session.
  ///
  /// The pointee's type follows the backing — `z_view_keyexpr_t` or
  /// `z_owned_keyexpr_t` — so this is only safe where the backing is known.
  /// Use [loanedKeyExpr], which is backing-aware, for everything else.
  Pointer<Void> get nativePtr {
    _ensureAlive();
    return _kePtr;
  }

  /// @nodoc
  ///
  /// Internal: the loaned key expression handle, for the op surface and for
  /// unstable-door extensions (`session_advanced_ext.dart`). Loaning is this
  /// library's business — a caller must not re-implement it, because which
  /// loan applies depends on the backing and getting it wrong is a type
  /// confusion, not a compile error. Not part of the public contract.
  @internal
  Pointer<Void> get loanedKeyExpr {
    _ensureAlive();
    return (_isOwned
            ? bindings.zd_keyexpr_loan(_kePtr.cast())
            : bindings.zd_view_keyexpr_loan(_kePtr.cast()))
        as Pointer<Void>;
  }

  /// @nodoc
  ///
  /// Internal: undeclares this key expression from [loanedSession].
  ///
  /// 🔴 Canon takes the value out of the handle **before** it checks anything,
  /// so the handle is dead on every return code — including errors. This
  /// mirrors that exactly: the handle is marked and its slot freed before the
  /// return code is inspected. A mark-only-on-success rendering would leave a
  /// live-looking wrapper around a gravestone on every error path.
  ///
  /// A view-backed key expression is rejected with an [ArgumentError] before
  /// any native call, and is **not** consumed: `z_undeclare_keyexpr` takes a
  /// `z_moved_keyexpr_t*`, so the call is unformable at the canon seam and no
  /// canon call runs.
  @internal
  void undeclareFrom(Pointer<Void> loanedSession) {
    _ensureAlive();
    if (!_isOwned) {
      throw ArgumentError.value(
        this,
        'keyExpr',
        'is not a declared key expression; only a KeyExpr returned by '
            'Session.declareKeyExpr can be undeclared',
      );
    }
    final rc = bindings.zd_undeclare_keyexpr(
      loanedSession.cast(),
      _kePtr.cast(),
    );
    // Unconditional, and before the rc check: canon's take-before-check means
    // the handle is already a gravestone whatever this returned. The slot
    // itself is Dart-`calloc`'d storage canon never owned, so freeing it here
    // is what closes the declare/undeclare cycle.
    _undeclared = true;
    // ⛔ WITH the unconditional free, and BEFORE the rc check. Canon takes the
    // handle before checking anything, so it is a gravestone whatever this
    // returned -- and the slot is freed on both paths. A detach placed after
    // the throw would leave the net armed over freed memory on exactly the
    // failure path.
    _detachNet();
    calloc.free(_kePtr);
    if (rc != 0) {
      throw ZenohException('Failed to undeclare key expression', rc);
    }
  }

  /// Returns the key expression as a Dart string.
  ///
  /// A declared key expression reads back as the expression it was declared
  /// from, not as its numeric id.
  ///
  /// Throws [StateError] if this [KeyExpr] has been disposed or undeclared.
  String get value {
    final loaned = loanedKeyExpr;
    final viewStr = calloc.allocate<Void>(bindings.zd_view_string_sizeof());
    try {
      bindings.zd_keyexpr_as_view_string(loaned.cast(), viewStr.cast());
      final data = bindings.zd_view_string_data(viewStr.cast());
      final len = bindings.zd_view_string_len(viewStr.cast());
      return data.cast<Utf8>().toDartString(length: len);
    } finally {
      calloc.free(viewStr);
    }
  }

  /// Releases native resources held by this key expression.
  ///
  /// This is a **local** release. For a key expression obtained from
  /// `Session.declareKeyExpr`, it frees this handle and leaves the session's
  /// registration in place until the session is closed — use
  /// `Session.undeclareKeyExpr` to unregister it.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  ///
  /// Also **detaches this object's finalizer**, so the safety net cannot
  /// release it a second time.
  ///
  /// Throws [StateError] if this key expression has been undeclared: undeclare
  /// already released everything, so a later dispose is a bug rather than a
  /// no-op.
  void dispose() {
    _ensureNotUndeclared();
    if (_disposed) return;
    _disposed = true;
    // Detach BOTH shapes before releasing, and after the guard above: a
    // dispose that throws because this was undeclared must not take the net
    // down, and on that path `undeclareFrom` has already detached.
    _detachNet();
    if (_isOwned) {
      bindings.zd_keyexpr_drop(_kePtr.cast());
    } else {
      malloc.free(_nativeStr);
    }
    calloc.free(_kePtr);
  }

  /// Returns an independent copy of this key expression.
  ///
  /// Whatever this handle's backing, the clone is an **owned** key expression
  /// with an independent lifetime: dispose this one and the clone still reads
  /// back, still delivers, and still answers relations.
  ///
  /// A clone of a declared key expression is itself a declared key expression:
  /// it can be undeclared in its own right, and undeclaring it leaves this
  /// handle untouched.
  ///
  /// The caller must [dispose] the returned handle.
  ///
  /// Throws [StateError] if this key expression is no longer alive.
  KeyExpr clone() {
    final loaned = loanedKeyExpr;
    if (_isOwned) {
      final slot = calloc.allocate<Void>(bindings.zd_keyexpr_sizeof());
      bindings.zd_keyexpr_clone(slot.cast(), loaned.cast());
      return KeyExpr._owned(slot);
    }
    // ⚠️ A view backing does not own its bytes -- it borrows the buffer this
    // object allocated -- and canon's `z_keyexpr_clone` clones what the source
    // HOLDS, which for a view is the borrow. Measured: clone a view-backed
    // handle, dispose the source, and the clone reads freed memory. So the
    // view path goes through canon's COPYING constructor instead. The two
    // branches are canon's semantics, not a preference.
    final viewStr = calloc.allocate<Void>(bindings.zd_view_string_sizeof());
    try {
      bindings.zd_keyexpr_as_view_string(loaned.cast(), viewStr.cast());
      final data = bindings.zd_view_string_data(viewStr.cast());
      final len = bindings.zd_view_string_len(viewStr.cast());
      final slot = calloc.allocate<Void>(bindings.zd_keyexpr_sizeof());
      final rc = bindings.zd_keyexpr_from_substr(slot.cast(), data, len);
      if (rc != 0) {
        calloc.free(slot);
        throw ZenohException('Failed to clone key expression', rc);
      }
      return KeyExpr._owned(slot);
    } finally {
      calloc.free(viewStr);
    }
  }

  /// Returns a new key expression with [right] appended, with no separator.
  ///
  /// `KeyExpr('FOO').concat('BAR')` is `FOOBAR`. Prefer [join] where a `/`
  /// belongs between the two: zenoh can exploit the hierarchical separation
  /// it inserts.
  ///
  /// [right] crosses to native as a pointer and a byte length, so an interior
  /// NUL is carried rather than truncating the operand. An empty [right] is
  /// legal and returns a copy of this expression.
  ///
  /// The result is an **owned** key expression the caller must [dispose].
  /// This receiver is unaffected.
  ///
  /// Throws [ZenohException] if the composition is invalid — notably `-128`
  /// for concatenating an expression starting with `*` onto one ending with
  /// `*`, which canon forbids outright, and for a right operand that is not
  /// itself composable. Throws [StateError] if this key expression is no
  /// longer alive.
  KeyExpr concat(String right) {
    final loaned = loanedKeyExpr;
    final encoded = utf8.encode(right);
    // Never NULL, even for an empty right: canon builds a Rust slice from
    // this pointer and slice::from_raw_parts(NULL, 0) is undefined behaviour.
    final rightPtr = _copyToNative(encoded);
    final slot = calloc.allocate<Void>(bindings.zd_keyexpr_sizeof());
    try {
      final rc = bindings.zd_keyexpr_concat(
        slot.cast(),
        loaned.cast(),
        rightPtr.cast(),
        encoded.length,
      );
      if (rc != 0) {
        calloc.free(slot);
        throw ZenohException('Failed to concatenate key expression', rc);
      }
      return KeyExpr._owned(slot);
    } finally {
      malloc.free(rightPtr);
    }
  }

  /// Returns a new key expression joining this one to [other] with a `/`.
  ///
  /// `KeyExpr('FOO').join('BAR')` is `FOO/BAR`. The separator is inserted by
  /// canon, not by this binding.
  ///
  /// [other] is a `String` or a [KeyExpr]; a [KeyExpr] argument is loaned, not
  /// consumed, and remains the caller's to dispose. Unlike [concat]'s right
  /// operand — a raw byte range — a join's right operand must itself be a
  /// valid key expression, which is what makes the union the natural shape
  /// here.
  ///
  /// The result is an **owned** key expression the caller must [dispose].
  ///
  /// Throws [ArgumentError] if [other] is neither a `String` nor a [KeyExpr].
  /// Throws [ZenohException] if the join is invalid. Throws [StateError] if
  /// either key expression is no longer alive.
  KeyExpr join(Object other) {
    final loaned = loanedKeyExpr;
    return withLoanedKeyExpr(other, 'other', (loanedRight) {
      final slot = calloc.allocate<Void>(bindings.zd_keyexpr_sizeof());
      final rc = bindings.zd_keyexpr_join(
        slot.cast(),
        loaned.cast(),
        loanedRight.cast(),
      );
      if (rc != 0) {
        calloc.free(slot);
        throw ZenohException('Failed to join key expression', rc);
      }
      return KeyExpr._owned(slot);
    });
  }

  /// Returns true if this key expression intersects with [other].
  ///
  /// Two key expressions intersect if there exists at least one key
  /// that belongs to both sets.
  ///
  /// [other] may have any backing: the comparison is made on loaned handles.
  /// (`loanedKeyExpr` is what guards both operands — a dead one throws
  /// [StateError] there, before any native call.)
  bool intersects(KeyExpr other) => bindings.zd_keyexpr_intersects(
    loanedKeyExpr.cast(),
    other.loanedKeyExpr.cast(),
  );

  /// Returns true if this key expression includes [other].
  ///
  /// A key expression includes another if every key in [other]
  /// is also contained in this expression.
  bool includes(KeyExpr other) => bindings.zd_keyexpr_includes(
    loanedKeyExpr.cast(),
    other.loanedKeyExpr.cast(),
  );

  /// Returns true if this key expression is equal to [other]
  /// in zenoh semantics.
  bool equals(KeyExpr other) => bindings.zd_keyexpr_equals(
    loanedKeyExpr.cast(),
    other.loanedKeyExpr.cast(),
  );

  void _ensureAlive() {
    _ensureNotUndeclared();
    if (_disposed) throw StateError('KeyExpr has been disposed');
  }

  void _ensureNotUndeclared() {
    if (_undeclared) throw StateError('KeyExpr has been undeclared');
  }
}
