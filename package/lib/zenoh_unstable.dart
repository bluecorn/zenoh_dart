/// Dart bindings for Zenoh — the stable API plus the unstable/SHM surface.
///
/// Importing this library opts in to canon's unstable tier
/// (`Z_FEATURE_UNSTABLE_API` / `Z_FEATURE_SHARED_MEMORY`). These APIs work as
/// advertised but may change in a future release, mirroring canon's own
/// unstable-feature contract.
///
/// This door is a strict superset of `zenoh.dart` (re-exported in full), so a
/// consumer writes a single import. It requires the `unstable` native variant;
/// selecting it and the resulting runtime gate are described in the README.
///
/// ⛔ EVERY DIRECTIVE NAMING A `src/` PATH ALLOW-LISTS. A bare
/// `export 'src/x.dart';` hands out every public declaration that file will
/// EVER carry, so a helper added to it in some later unit joins this
/// package's public API with nobody having decided that. A `show` clause
/// makes the decision explicit and makes each addition to it a reviewable
/// line.
///
/// ⭐ THE ONE EXEMPTION IS THE LAST DIRECTIVE, AND IT IS BARE ON PURPOSE.
/// `export 'zenoh.dart';` inherits the stable door's own clauses — every
/// name it hands out was already decided there, one reviewable line at a
/// time. Repeating that list here would create a second place to forget,
/// and the two copies would drift the first time the stable door changed.
/// The eleven directives above it name a leaf library that allow-lists
/// nothing itself, so for those the decision has nowhere else to live.
///
/// The lists are derived from the per-file public-declaration census
/// (`scripts/instruments/export_surface.dart`), not written by
/// hand, and are sorted the way `combinators_ordering` wants them: plain
/// case-sensitive comparison, so uppercase sorts before lowercase.
library;

export 'src/unstable/advanced_publisher.dart'
    show
        AdvancedPublisher,
        AdvancedPublisherCacheOptions,
        AdvancedPublisherOptions,
        HeartbeatMode;
export 'src/unstable/advanced_subscriber.dart'
    show
        AdvancedSubscriber,
        AdvancedSubscriberOptions,
        DetectPublishersOptions,
        MissEvent;
export 'src/unstable/alloc_alignment.dart' show AllocAlignment;
export 'src/unstable/alloc_error_kind.dart' show AllocErrorKind;
// ⚠️ `LayoutError` is declared here, beside the allocation results, and not
// in the file named for the layout enum next to it. The census is what says
// so; a list written from the file names would have put it one line down.
export 'src/unstable/alloc_result.dart'
    show AllocError, AllocOk, AllocResult, LayoutError;
export 'src/unstable/bytes_shm_ext.dart' show ShmBytes;
// Shows the type only. `requireShm` and `requireUnstable` are left out: they
// are the src/-internal gates that refuse an unstable-tier call on a native
// built without the feature, not public surface. This is the one clause the
// door already carried, and the conversion changed nothing about it.
export 'src/unstable/features.dart' show ZenohFeatures;
export 'src/unstable/layout_error_kind.dart' show LayoutErrorKind;
export 'src/unstable/session_advanced_ext.dart' show AdvancedSession;
export 'src/unstable/shm_mut_buffer.dart' show ShmMutBuffer;
export 'src/unstable/shm_provider.dart' show ShmProvider;
export 'zenoh.dart';
