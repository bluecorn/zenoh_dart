/// The outcome of one SHM allocation request.
///
/// Canon reports every allocation through a **tagged three-way result**, not
/// through success/failure: `zc_buf_layout_alloc_status_t` is `OK` (0),
/// `ALLOC_ERROR` (1) or `LAYOUT_ERROR` (2), and each failure status selects
/// its own error enum. This family preserves every distinction canon draws,
/// so a consumer can tell *my arguments are wrong* from *the pool is full*
/// — two conditions an earlier nullable rendering of this API reported with
/// the same `null`.
///
/// Switch over it exhaustively and write no `default` arm:
///
/// ```dart
/// switch (provider.alloc(1024)) {
///   case AllocOk(:final buffer):
///     // buffer.write(bytes), then buffer.toBytes()
///   case AllocError(:final kind):
///     // kind tells you whether a retry could ever help
///   case LayoutError(:final kind):
///     // the request itself was refused — fix the arguments
/// }
/// ```
///
/// A *call* failure — the provider could not be constructed, a canon entry
/// returned a negative code — is not a member of this family. Those throw
/// `ZenohException`, exactly as everywhere else in the binding.
library;

import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/unstable/alloc_error_kind.dart';
import 'package:zenoh_dart/src/unstable/layout_error_kind.dart';
import 'package:zenoh_dart/src/unstable/shm_mut_buffer.dart';

/// The outcome of an allocation on an `ShmProvider`.
///
/// Sealed: [AllocOk], [AllocError] and [LayoutError] are the only members —
/// exactly canon's three statuses, no fourth state invented and none dropped
/// — so a `switch` over them is exhaustive without a `default`.
sealed class AllocResult {
  /// Allows the variants below to be `const`.
  const AllocResult();

  /// Decodes the two **failure** arms of canon's tagged result.
  ///
  /// This is the single production decoder for `ALLOC_ERROR` and
  /// `LAYOUT_ERROR`; the OK arm is built at the call site, because only the
  /// call site holds the buffer canon handed back. It is exposed rather than
  /// private so the seam under test is the seam in use, not a parallel copy
  /// that can drift.
  ///
  /// [status] selects which of the two raw fields is read. The other is
  /// **not** read at all: canon backfills the unselected field with an
  /// arbitrary member (on OK it writes `OTHER` and
  /// `PROVIDER_INCOMPATIBLE_LAYOUT`), so a decoder that trusted both fields
  /// would surface a meaningless second cause. The shim already gravestones
  /// the unselected field to `-1`; reading only the selected one is the second
  /// half of the same defence.
  ///
  /// Throws [ZenohException] if [status] is not one of canon's two failure
  /// statuses. An out-of-domain status is a **contract violation**, never
  /// silently mapped onto a real variant and never a minted fourth one.
  /// `0` reaches here only through a caller bug — the OK arm is the call
  /// site's — and is reported the same way.
  ///
  /// Deliberately not annotated `@visibleForTesting`: the binding itself calls
  /// this on every failing allocation, so the annotation would be false and
  /// the alternative — a private body behind a test-only façade — would put a
  /// second entry point where the point is that there is only one.
  static AllocResult failureFromWire(
    int status,
    int allocErrorRaw,
    int layoutErrorRaw,
  ) => switch (status) {
    1 => AllocError(AllocErrorKind.fromWire(allocErrorRaw)),
    2 => LayoutError(LayoutErrorKind.fromWire(layoutErrorRaw)),
    _ => throw ZenohException(
      'SHM allocation reported an unknown status',
      status,
    ),
  };
}

/// The allocation succeeded; [buffer] is the memory canon handed back.
///
/// Canon's `ZC_BUF_LAYOUT_ALLOC_STATUS_OK` — *"Allocation ok"*.
final class AllocOk extends AllocResult {
  /// Wraps the [buffer] the provider allocated.
  const AllocOk(this.buffer);

  /// The allocated buffer. Write through `data`, then `toBytes()`.
  final ShmMutBuffer buffer;
}

/// The request was well formed; the provider could not satisfy it.
///
/// Canon's `ZC_BUF_LAYOUT_ALLOC_STATUS_ALLOC_ERROR` — *"Allocation error"* —
/// carrying canon's own `z_alloc_error_t` as [kind].
final class AllocError extends AllocResult {
  /// Wraps the allocation-failure [kind] canon reported.
  const AllocError(this.kind);

  /// Why the provider could not satisfy the request.
  final AllocErrorKind kind;
}

/// The request never became a layout the provider could act on.
///
/// Canon's `ZC_BUF_LAYOUT_ALLOC_STATUS_LAYOUT_ERROR` — *"Layouting error"* —
/// carrying canon's own `z_layout_error_t` as [kind]. This is a different
/// outcome from [AllocError], and the difference is actionable: a layout error
/// says the arguments are wrong, so retrying unchanged can never help.
final class LayoutError extends AllocResult {
  /// Wraps the layout-failure [kind] canon reported.
  const LayoutError(this.kind);

  /// Why the request could not be laid out.
  final LayoutErrorKind kind;
}
