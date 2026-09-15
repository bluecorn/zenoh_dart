/// Why an SHM allocation failed *as a layout*.
///
/// Canon's `z_layout_error_t`, carried by [LayoutError] — the arm canon
/// reports when the request never became a layout the provider could act on.
/// This is a different outcome from running out of room; see `AllocErrorKind`.
library;

import 'package:zenoh_dart/src/unstable/alloc_result.dart' show LayoutError;

/// Canon's layout-error vocabulary, with canon's own wire values.
///
/// The C enum assigns no explicit initialisers, so C's implicit numbering
/// gives 0/1. Those numbers are written out here rather than taken from
/// declaration order.
enum LayoutErrorKind {
  /// *"Layout arguments are incorrect."* — canon's own words.
  ///
  /// The measured outcome of `size: 0`, and of an alignment `pow` canon reads
  /// as nonsensical rather than merely unsupported. Note what this is **not**:
  /// a zero-size request is a *layout* error, not the pool exhaustion an
  /// earlier nullable rendering of this API conflated it with.
  incorrectLayoutArgs(0),

  /// *"Layout incompatible with provider."* — canon's own words.
  ///
  /// The provider accepts only its own construction layout. On the default
  /// provider this binding constructs, that means any alignment stricter than
  /// `pow: 0` lands here — the ceiling is documented on
  /// `ShmProvider.alloc`'s `alignment` parameter, and lifting it needs a
  /// layout-capable constructor, which is a carved capability.
  providerIncompatibleLayout(1),

  /// A wire value outside canon's domain.
  ///
  /// **A binding-labelled sentinel, not a canon member** — canon designates no
  /// default for this enum. See `AllocErrorKind.unknown`, which carries the
  /// same reasoning and the same `-1`.
  unknown(-1);

  const LayoutErrorKind(this.value);

  /// The zenoh-c wire value. Explicit; never derived from declaration order.
  final int value;

  /// Decodes a raw `z_layout_error_t` value.
  ///
  /// Total: every value outside canon's domain yields [unknown].
  static LayoutErrorKind fromWire(int raw) => switch (raw) {
    0 => incorrectLayoutArgs,
    1 => providerIncompatibleLayout,
    _ => unknown,
  };
}
