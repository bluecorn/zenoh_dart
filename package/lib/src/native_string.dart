import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

/// Marshals [value] into a native UTF-8 buffer whose length travels with it.
///
/// The counterpart of `_zd_str_to_cobject` on the receive side: a value whose
/// domain admits an interior NUL cannot cross as a C string, because the far
/// side measures it with `strlen` and silently truncates. Every caller of a
/// canon `*_with_parameters_substr` entry marshals through here.
///
/// Returns `(nullptr, 0)` for a null [value] — canon's own spelling for
/// "absent" (`CStringView::new_borrowed` accepts a NULL pointer at length 0,
/// and refuses only NULL-with-a-length).
///
/// A present-but-empty string gets a **non-null** one-byte allocation at
/// length 0, so the absent/empty distinction survives our side of the seam
/// even where canon collapses it downstream. That mirrors the empty-vs-absent
/// discipline the attachment and payload paths already carry.
///
/// **The caller owns the pointer** and must free it on every path — `ptr` is
/// `nullptr` exactly when [value] is null, so the release is
/// `if (ptr != nullptr) calloc.free(ptr)` inside the caller's existing
/// outer `finally`. Returning the raw pointer rather than running a callback
/// is deliberate: these call sites already have one `finally` covering several
/// native buffers, and nesting a closure per buffer would fragment it.
@internal
({Pointer<Char> ptr, int len}) allocLengthCarriedUtf8(String? value) {
  if (value == null) return (ptr: nullptr, len: 0);
  final bytes = utf8.encode(value);
  final buffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  if (bytes.isNotEmpty) {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
  }
  return (ptr: buffer.cast<Char>(), len: bytes.length);
}
