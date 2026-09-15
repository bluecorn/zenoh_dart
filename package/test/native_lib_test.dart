import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/unstable/features.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group('ensureInitialized with DynamicLibrary.open', () {
    test('completes without error', () {
      expect(ensureInitialized, returnsNormally);
    });

    test('is idempotent', () {
      ensureInitialized();
      expect(ensureInitialized, returnsNormally);
    });

    test('bindings resolve after initialization', () {
      ensureInitialized();
      final size = bindings.zd_config_sizeof();
      expect(size, greaterThan(0));
    });

    test('zd_init_log does not crash', () {
      ensureInitialized();
      expect(
        () => bindings.zd_init_log('error'.toNativeUtf8().cast()),
        returnsNormally,
      );
    });

    test('Session.open works', () async {
      final session = await Session.open();
      expect(session, isNotNull);
      session.close();
    });
  });

  // R3: the zd_features OFF leg, which had never run.
  //
  // This group used to be skipped whenever `ZenohFeatures.hasSharedMemory` was
  // false -- that is, on exactly the variant whose behaviour the group's own
  // comment called "the discriminating OFF-case". The skip reason waited on
  // variant builds that now exist (native/linux/x86_64/{stable,unstable}/), so
  // the gate is gone and both directions are asserted.
  //
  // The repair is not just "drop the skip", because branching the assertion on
  // `ZenohFeatures.hasSharedMemory` would be circular: that getter reads
  // `zd_features()` itself, so the test would assert the bitmask against the
  // bitmask and pass on any value.
  //
  // The independent oracle is which symbols the loaded .so actually exports.
  // The shim's SHM and unstable functions are #ifdef-compiled, so they are
  // physically absent from a stable build -- measured on the prebuilts:
  //   stable/libzenoh_dart.so    147 zd_* symbols, no zd_shm_provider_new,
  //                              no zd_declare_advanced_publisher
  //   unstable/libzenoh_dart.so  172 zd_* symbols, both present
  // Comparing the bitmask against symbol presence therefore fails if the two
  // ever disagree, in either direction, on either variant.
  group('zd_features', () {
    // Feature bits mirror the src/zenoh_dart.h ZD_FEATURE_* macros. ffigen's
    // zd_.* filter is lowercase-only, so those uppercase macros are not
    // emitted to bindings.dart — the bit positions are mirrored here.
    const unstableBit = 1 << 0; // ZD_FEATURE_UNSTABLE_API
    const shmBit = 1 << 1; // ZD_FEATURE_SHARED_MEMORY

    // One representative #ifdef-guarded export per feature.
    const shmSymbol = 'zd_shm_provider_new'; // Z_FEATURE_SHARED_MEMORY
    const unstableSymbol = 'zd_declare_advanced_publisher'; // ..._UNSTABLE_API

    // Re-open the library the loader chose. dlopen refcounts, so this hands
    // back the handle already in use rather than mapping a second copy -- the
    // symbol answers are about the native the suite is actually running on.
    DynamicLibrary loadedLibrary() {
      ensureInitialized();
      final path = resolvedLibraryPath;
      return DynamicLibrary.open(path ?? 'libzenoh_dart.so');
    }

    test('the bitmask agrees with the symbols the native exports', () {
      final features = bindings.zd_features();
      final lib = loadedLibrary();

      final exportsShm = lib.providesSymbol(shmSymbol);
      final exportsUnstable = lib.providesSymbol(unstableSymbol);

      expect(
        features & shmBit != 0,
        equals(exportsShm),
        reason:
            'SHM bit says ${features & shmBit != 0}, but $shmSymbol '
            'is ${exportsShm ? "present" : "absent"}',
      );
      expect(
        features & unstableBit != 0,
        equals(exportsUnstable),
        reason:
            'unstable bit says ${features & unstableBit != 0}, but '
            '$unstableSymbol is ${exportsUnstable ? "present" : "absent"}',
      );
    });

    test('the bitmask carries no bits outside the two known features', () {
      final features = bindings.zd_features();

      expect(
        features & ~(unstableBit | shmBit),
        isZero,
        reason: 'stray feature bits in 0x${features.toRadixString(16)}',
      );
    });

    // The variant-agreement control. `ZenohFeatures` is what every unstable
    // entrypoint and every `skip:` ternary in this suite gates on; if it ever
    // disagreed with the raw bitmask, the whole skip matrix would be reporting
    // on a variant other than the one loaded.
    test('ZenohFeatures mirrors the raw bitmask', () {
      final features = bindings.zd_features();

      expect(ZenohFeatures.hasSharedMemory, equals(features & shmBit != 0));
      expect(ZenohFeatures.hasUnstableApi, equals(features & unstableBit != 0));
    });
  });

  // The suite's own load-path guard.
  //
  // The suite runs off `native/linux/x86_64/<variant>/`, not off the build
  // hook's staged copy in `.dart_tool/lib/`, and `scripts/test.sh` is what
  // arranges that by exporting ZENOH_DART_VARIANT. The reason is a toolchain
  // defect, not a preference: `dart run`/`dart test` re-stage the bundled
  // native assets on every invocation, unconditionally and non-atomically
  // (`pkg/dartdev/lib/src/native_assets_bundling.dart` carries a
  // `TODO(dartbug.com/59668)` above the copy, and its `copyTo` comment names
  // the dlopen-truncation hazard; dart-lang/sdk#62361). 45 of this package's 103
  // default-suite test files spawn a child `dart run` while this process has
  // that same 15.6 MB `.so` mmap'ed, so the file under our own mapping gets
  // rewritten mid-run (counting instrument: header of `scripts/test.sh`).
  // The observable is SIGBUS.
  //
  // These cells are the second lock. `scripts/test.sh` refuses to start on a
  // disagreement; running the suite any other way lands here instead, so
  // bypassing the script does not bypass the check.
  group('library resolution', () {
    /// The variant `package/pubspec.yaml` declares under
    /// `hooks: user_defines: zenoh_dart: variant:`.
    ///
    /// Read from the pubspec rather than pinned to a constant, because what
    /// the cells below have to catch is the two sides DISAGREEING -- a literal
    /// here would only be a third opinion to disagree with.
    String declaredVariant() {
      final text = File('pubspec.yaml').readAsStringSync();
      // Anchored on a column-0 `hooks:` so the `hooks: ^2.0.0` DEPENDENCY,
      // indented under `dependencies:`, cannot match.
      final hooks = RegExp(r'^hooks:[ \t]*$', multiLine: true).firstMatch(text);
      expect(
        hooks,
        isNotNull,
        reason: 'no top-level `hooks:` block in package/pubspec.yaml',
      );
      final variant = RegExp(
        r'^[ \t]+variant:[ \t]*([^\s#]+)',
        multiLine: true,
      ).firstMatch(text.substring(hooks!.end));
      expect(
        variant,
        isNotNull,
        reason:
            'no hooks.user_defines.zenoh_dart.variant in '
            'package/pubspec.yaml',
      );
      return variant!.group(1)!;
    }

    test('the suite is not running off the toolchain-rewritten staging copy', () {
      ensureInitialized();

      expect(
        resolvedLibraryPath,
        isNotNull,
        reason: 'a path load is expected on Linux, not soname resolution',
      );
      expect(
        resolvedLibraryPath,
        isNot(contains('/.dart_tool/')),
        reason:
            'This process loaded the native from the copy the Dart '
            'toolchain rewrites on every `dart run`, and 45 of the 103 '
            'default-suite files spawn one. Run the suite via `scripts/test.sh` '
            '(which '
            'exports ZENOH_DART_VARIANT from the pubspec) rather than calling '
            '`fvm dart test` directly.',
      );
    });

    test('the loaded variant is the one package/pubspec.yaml declares', () {
      ensureInitialized();
      final declared = declaredVariant();

      // Both halves are asserted on purpose. The env var is what the loader
      // reads; the path is what it did with it. Asserting only the first
      // would pass on a value the loader rejected, and asserting only the
      // second would pass if some future probe reached the right directory
      // for the wrong reason.
      expect(
        Platform.environment['ZENOH_DART_VARIANT'],
        equals(declared),
        reason:
            'ZENOH_DART_VARIANT and the pubspec disagree. Preferring '
            'either silently is the hazard: the other native carries a '
            'different feature set, and the cells that need the missing '
            'features SKIP rather than fail -- so the suite would go green '
            'while testing less than it claims.',
      );
      expect(
        resolvedLibraryPath,
        contains('/native/linux/x86_64/$declared/'),
        reason: 'the loader did not land in the declared variant directory',
      );
    });

    test('a child process inherits the selection', () async {
      // The cell that covers the other 44 spawning files. They all spawn
      // `dart run` without passing ZENOH_DART_VARIANT themselves, so their
      // children are protected only if the parent's environment reaches them.
      final declared = declaredVariant();
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/variant_override_harness.dart'],
        workingDirectory: Directory.current.path,
      );
      final out = '${result.stdout}${result.stderr}';

      expect(out, contains('LOADED='), reason: 'harness output: $out');
      expect(
        out,
        contains('/native/linux/x86_64/$declared/'),
        reason: 'a child loaded from somewhere else: $out',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('with no override the loader still prefers the hook output', () async {
      // This assertion used to run IN-PROCESS, and it was the probe-order
      // regression guard: the loader prefers `.dart_tool/lib/` because that is
      // the only VARIANT-CORRECT location (the hook stages whichever variant
      // `user_defines` selected). Sound only on Dart >= 3.12.2, which dropped
      // the eager code-asset dlopen behind the v0.6.2 tokio-waker crash (Gate
      // A, `development/build/08-gate-a-results.md` §3); the pubspec SDK floor
      // enforces that, and `test/interprocess_test.dart` is what catches a
      // crash regression.
      //
      // It moved to a child because the suite now runs WITH the override set,
      // so an in-process assertion here would only have been measuring the
      // ambient environment. Tests control their environment; they never
      // inherit it.
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/variant_override_harness.dart'],
        // Empty, not absent: `Process.run` MERGES this map into the inherited
        // environment and has no way to delete a key. The loader treats an
        // empty value as unset (`_validatedVariantOverride` in
        // `native_lib.dart`), so this is how a child gets the un-overridden
        // probe order.
        environment: {'ZENOH_DART_VARIANT': ''},
        workingDirectory: Directory.current.path,
      );
      final out = '${result.stdout}${result.stderr}';

      expect(out, contains('LOADED='), reason: 'harness output: $out');
      expect(
        out,
        contains('.dart_tool/lib/'),
        reason:
            'with no override the probe should land on the hook output, '
            'not fall through elsewhere: $out',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('ZenohException', () {
    test('carries message and return code', () {
      final exception = ZenohException('test error', -1);
      expect(exception.message, equals('test error'));
      expect(exception.returnCode, equals(-1));
      final str = exception.toString();
      expect(str, contains('test error'));
      expect(str, contains('-1'));
    });
  });

  // --- Seed [D1] slice 16: both load failures carry their cause ---
  group('[D1] S16 — a load failure names what went wrong', () {
    late Directory tmp;
    setUpAll(() => tmp = Directory.systemTemp.createTempSync('zd_d1_s16_'));
    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<String> runLoader(Map<String, String> environment) async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/helpers/variant_override_harness.dart'],
        environment: environment,
      );
      return '${result.stdout}${result.stderr}';
    }

    test('a found-but-unloadable library fails with context, not a raw VM '
        'exception', () async {
      // ⛔ THE PROBE ORDER SAID THIS FILE WAS THE RIGHT ONE AND THE LOADER
      // DISAGREED. That is its own failure, and it used to propagate the VM's
      // bare exception with no context: no path, and no statement of what the
      // file was expected to be. The two commonest causes -- a build for
      // another architecture, and a truncated or half-written file -- are
      // indistinguishable from the VM's message alone.
      final fakeVariant = Directory('${tmp.path}/native/linux/x86_64/bogus')
        ..createSync(recursive: true);
      File('${fakeVariant.path}/libzenoh_dart.so')
          .writeAsStringSync('not an ELF shared object at all');

      final out = await runLoader({
        'ZENOH_DART_VARIANT': 'bogus',
        'ZD_TEST_NATIVE_ROOT': tmp.path,
      });
      // The loader refuses either way; what this cell pins is that the
      // refusal NAMES SOMETHING. A bare VM message would carry neither.
      expect(out, contains('THREW='));
      expect(
        out,
        contains('bogus'),
        reason:
            'the failure does not name the variant or path it tried, so a '
            'reader cannot tell which candidate failed',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the two load paths both carry their underlying cause', () {
      // Asserted structurally as well as behaviourally: the last-resort arm
      // used to be `on Object` with NO BINDING, which discarded the one
      // sentence saying what the OS linker actually objected to.
      final loader = File('lib/src/native_lib.dart').readAsStringSync();
      // ⚠️ THE NEGATIVES SCAN CODE, NOT PROSE. This file's comments DESCRIBE
      // the unbound-catch shape they replaced, so a whole-file `isNot` fails
      // on the very explanation of the fix — which it did, first run. Code
      // lines only.
      final code = const LineSplitter()
          .convert(loader)
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        code,
        isNot(contains('on Object {')),
        reason:
            'an unbound catch is back on the load path, and it can only '
            'discard the cause',
      );
      expect(loader, contains(r'The loader said: $e'));
      expect(loader, contains(r'The linker said: $e'));
      // ⛔ NARROW, not `on Object`: an unknown failure class must propagate
      // unwrapped rather than be reported as this one.
      expect(loader, contains('on ArgumentError catch (e)'));
      expect(
        code,
        isNot(contains('on Object catch (_)')),
        reason: 'the S-9 lesson is not re-imported',
      );
    });

    test('the successful path stays silent', () async {
      // No diagnostic overhead on the normal route, and the winner is still
      // recorded — the accessor slice 15 exposes depends on it.
      final out = await runLoader({'ZENOH_DART_VARIANT': 'unstable'});
      expect(out, contains('LOADED='));
      expect(out, contains('/unstable/'));
      expect(out, isNot(contains('THREW=')));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
