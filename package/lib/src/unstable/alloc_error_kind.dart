/// Why an SHM allocation failed *as an allocation*.
///
/// Canon's `z_alloc_error_t`, carried by [AllocError] — the arm canon reports
/// when the request itself was well formed but the provider could not satisfy
/// it. A *layout* failure (the request was malformed, or the provider cannot
/// honour it) is a different canon outcome carried by a different variant; see
/// `LayoutErrorKind`.
library;

import 'package:zenoh_dart/src/unstable/alloc_result.dart' show AllocError;

/// Canon's allocation-error vocabulary, with canon's own wire values.
///
/// The C enum assigns no explicit initialisers, so C's implicit numbering
/// gives 0/1/2. Those numbers are written out here rather than taken from
/// declaration order, so reordering the members — a change every linter treats
/// as cosmetic — cannot silently change what the two layers agree they mean.
enum AllocErrorKind {
  /// *"Defragmentation needed."* — canon's own words.
  ///
  /// Canon documents **no retryability relationship** for this member: it does
  /// not say that a retry after defragmenting will succeed, and this binding
  /// invents no such recipe. What it does say is what the actionable arm is —
  /// `ShmProvider.defragment()` is the manual call whose name matches this
  /// condition, and `ShmProvider.allocGcDefrag` (and its blocking sibling) are
  /// the strategies that defragment on your behalf before giving up.
  ///
  /// ⚠️ Not observed in practice at this pin: the probed recipe family never
  /// produced this member through a real allocation — a drop-then-realloc
  /// cycle and a three-buffer fragmentation recipe both reported OK or
  /// out-of-memory instead (`development/research/probes-seed7-20260819/`).
  /// It is bound because canon declares it, decoded because canon can return
  /// it, and left undriven by any cell rather than faked by one.
  needDefragment(0),

  /// *"The provider is out of memory."* — canon's own words.
  ///
  /// The measured outcome of asking for more than the pool can hold. Distinct
  /// from [needDefragment]: canon draws the line and this binding keeps it.
  outOfMemory(1),

  /// *"Other error."* — canon's own words.
  ///
  /// Canon's own catch-all member. Distinct from [unknown], which is this
  /// binding's sentinel for a value canon never defined.
  other(2),

  /// A wire value outside canon's domain.
  ///
  /// **A binding-labelled sentinel, not a canon member.** Canon designates no
  /// default for this enum, so an unrecognised raw totalizes here rather than
  /// being silently mapped onto a real member (which would report a specific
  /// cause the peer never sent) or throwing (which would turn a decode
  /// surprise into a crash). `-1` is outside canon's `{0,1,2}` domain *and* is
  /// the value the shim writes into the field its status did not select, so a
  /// misread field lands here rather than on a plausible-looking real member.
  unknown(-1);

  const AllocErrorKind(this.value);

  /// The zenoh-c wire value. Explicit; never derived from declaration order.
  final int value;

  /// Decodes a raw `z_alloc_error_t` value.
  ///
  /// Total: every value outside canon's domain yields [unknown].
  static AllocErrorKind fromWire(int raw) => switch (raw) {
    0 => needDefragment,
    1 => outOfMemory,
    2 => other,
    _ => unknown,
  };
}
