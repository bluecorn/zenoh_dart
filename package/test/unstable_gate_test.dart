import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

/// The unstable-door runtime gates (12- §3.3, §6.3).
///
/// Each unstable entrypoint fails loudly with an [UnsupportedError] when the
/// loaded native LACKS the feature — the `stable` variant. This is the error
/// path that turns the "unstable API imported, stable native loaded"
/// must-agree footgun into a self-fixing diagnostic; without a test it is never
/// exercised.
///
/// Under the `unstable` variant the gates do not fire, so each group self-skips
/// on the feature bit. The complementary halves are run across the 2x variant
/// matrix (12- §8 step 8): the throw is asserted under `stable`, the normal
/// behaviour under `unstable`.
void main() {
  group(
    'SHM gate throws under a stable native',
    () {
      test('ShmProvider construction throws UnsupportedError', () {
        expect(() => ShmProvider(size: 65536), throwsUnsupportedError);
      });

      test('ZBytes.isShmBacked throws UnsupportedError', () {
        final bytes = ZBytes.fromString('probe');
        addTearDown(bytes.dispose);
        expect(() => bytes.isShmBacked, throwsUnsupportedError);
      });

      // ⚠️ NO CELL IS OWED FOR THE ALLOCATION SURFACE, and the reasoning is
      // written here because this is where a reader would otherwise notice the
      // absence and assume an oversight.
      //
      // Seed #7 added a substantial surface — the three sync strategies, the
      // alignment parameter, defragment() and garbageCollect() — and not one
      // of them gets a gate cell. Every one is an INSTANCE member on
      // ShmProvider, and the only way to obtain an instance is the constructor
      // one line above, which already throws here. So a gate cell for
      // `provider.allocGc(…)` could never construct the provider it needs, and
      // would either be unwritable or would assert the constructor's throw a
      // second time under another name.
      //
      // The same applies to the free functions this seed did NOT add: there
      // are none. AllocResult, AllocErrorKind, LayoutErrorKind and
      // AllocAlignment are pure Dart types that touch no native symbol, so
      // they are constructible under a stable native and correctly have no
      // gate at all.
    },
    skip: ZenohFeatures.hasSharedMemory
        ? 'unstable variant — SHM gate does not fire'
        : false,
  );

  group(
    'Unstable-API gate throws under a stable native',
    () {
      late Session session;
      setUpAll(() async => session = await Session.open());
      tearDownAll(() => session.close());

      test('declareAdvancedPublisher throws UnsupportedError', () {
        expect(
          () => session.declareAdvancedPublisher('demo/gate'),
          throwsUnsupportedError,
        );
      });

      test('declareAdvancedSubscriber throws UnsupportedError', () {
        expect(
          () => session.declareAdvancedSubscriber('demo/gate'),
          throwsUnsupportedError,
        );
      });
    },
    skip: ZenohFeatures.hasUnstableApi
        ? 'unstable variant — unstable-API gate does not fire'
        : false,
  );
}
