/// The alignment an SHM allocation is laid out at.
///
/// Canon's `z_alloc_alignment_t`, which is a single `uint8_t pow`.
library;

/// An allocation alignment, expressed as a power of two.
///
/// **The alignment in bytes is `2^pow`** — so `pow: 0` is 1-byte (i.e.
/// unaligned), `pow: 3` is 8-byte alignment. Canon never states that rule in
/// prose anywhere in the C headers; it is pinned by canon's own constants
/// (`ALIGN_1_BYTE {0}`, `ALIGN_2_BYTES {1}`, `ALIGN_4_BYTES {2}`,
/// `ALIGN_8_BYTES {3}`) and by canon's unaligned entries, which implement
/// themselves by passing `pow: 0`. That equivalence is why passing `null` for
/// an `alignment` and passing `AllocAlignment(pow: 0)` are the same request.
///
/// **When a request is refused, which refusal you get follows a rule**, and it
/// is worth knowing because the two are differently actionable. The effective
/// alignment is `2^pow`; if it is **larger than the size you asked for**, canon
/// reports `incorrectLayoutArgs` — the pair itself is malformed, so no provider
/// could honour it. If the pair is well formed but stricter than the provider's
/// own layout, canon reports `providerIncompatibleLayout` — the request is
/// fine, this provider is the problem. The same `pow` can produce either,
/// depending on the size beside it.
///
/// ⚠️ **On the provider this binding constructs, only `pow: 0` succeeds.**
/// A default provider accepts only its own construction layout, so any
/// stricter alignment comes back as
/// `LayoutError(LayoutErrorKind.providerIncompatibleLayout)` — measured, and
/// canon-C behaves identically, so this is canon's property and not a binding
/// limitation. Lifting it needs a provider built with a layout, which is a
/// carved capability (the with-layout constructor family). The parameter is
/// bound anyway because that is strict parity, and because the refusal is the
/// deterministic driver for that discriminant.
///
/// The constructor is **not `const`**, deliberately: the domain guard is a
/// real `throw`, and a `const` constructor could only carry an `assert`, which
/// vanishes in a release build. A guard that protects only debug builds is
/// worse than none, because it reads as protection.
class AllocAlignment {
  /// Creates an alignment of `2^pow` bytes.
  ///
  /// Throws [ArgumentError] unless [pow] is in canon's `uint8_t` domain,
  /// 0..255. Rejecting here rather than at each allocation call means an
  /// out-of-domain value can never reach the FFI seam at all: there is no way
  /// to build a value that carries one.
  AllocAlignment({required this.pow}) {
    if (pow < 0 || pow > 255) {
      throw ArgumentError.value(
        pow,
        'pow',
        "must be in canon's uint8_t domain, 0..255",
      );
    }
  }

  /// The exponent: the alignment is `2^pow` bytes.
  ///
  /// Carried full-width to canon's `uint8_t` — every value in 0..255 crosses
  /// exactly as given.
  final int pow;
}
