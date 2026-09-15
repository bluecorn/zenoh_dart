import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../hook/build.dart' as hook;

/// Whether two files hold byte-identical content.
///
/// A content comparison rather than a hash so the test needs no new dependency
/// — and it answers the same question with no collision caveat.
bool _sameContent(File a, File b) {
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

/// Unit test for the native build hook (12- §4.3 copy + §4.4 dependency
/// declaration), driven in isolation via `testBuildHook`.
///
/// Passes `variant: unstable` explicitly, so it reads the on-disk
/// native/linux/x86_64/unstable/ prebuilts regardless of the pubspec's own
/// variant — i.e. it is correct under both halves of the 2x matrix.
void main() {
  test(
    'hook stages BOTH libs and declares the sources as dependencies',
    () async {
      await testBuildHook(
        mainMethod: hook.main,
        extensions: [
          CodeAssetExtension(
            targetArchitecture: Architecture.x64,
            targetOS: OS.linux,
            linkModePreference: LinkModePreference.dynamic,
          ),
        ],
        userDefines: PackageUserDefines(
          workspacePubspec: PackageUserDefinesSource(
            defines: {'variant': 'unstable'},
            basePath: Directory.current.uri,
          ),
        ),
        check: (input, output) {
          // §4.3: BOTH libraries copied into the SAME output directory, so the
          // shim resolves libzenohc.so via RUNPATH=$ORIGIN at load time.
          //
          // Existence is not identity. A green build proves a file arrived,
          // never *which* variant arrived — and a legacy top-level
          // native/linux/x86_64/*.so exists in this tree, so "some .so is
          // present" is a weak claim. The staged bytes are therefore matched
          // against the requested variant's source. Today one `source` URI
          // feeds both the copy and the dependency list, so this cannot
          // currently diverge; the check is here to keep it that way if those
          // paths are ever split.
          for (final name in const ['libzenoh_dart.so', 'libzenohc.so']) {
            final staged = File.fromUri(input.outputDirectory.resolve(name));
            expect(
              staged.existsSync(),
              isTrue,
              reason: '$name should be copied into the output directory',
            );

            final unstableSource = File(
              '${Directory.current.path}/native/linux/x86_64/unstable/$name',
            );
            expect(
              unstableSource.existsSync(),
              isTrue,
              reason:
                  'the unstable prebuilt must exist for this test to mean '
                  'anything: ${unstableSource.path}',
            );
            expect(
              _sameContent(staged, unstableSource),
              isTrue,
              reason:
                  'staged $name must be byte-identical to the UNSTABLE '
                  'prebuilt, not merely present',
            );
          }

          // Two code assets registered (bindings + zenohc), pointing at the
          // copies.
          expect(output.assets.code.length, 2);

          // §4.4: both SOURCE .so declared as dependencies, so `cmake install`
          // re-runs the hook and the ~2s dev loop is not stale. Sourced from
          // the requested variant subdir.
          final deps = output.dependencies.map((u) => u.toFilePath()).toList();
          for (final name in const ['libzenoh_dart.so', 'libzenohc.so']) {
            expect(
              deps.any(
                (d) => d
                    .replaceAll(r'\', '/')
                    .endsWith('native/linux/x86_64/unstable/$name'),
              ),
              isTrue,
              reason: 'source $name (unstable variant) should be a dependency',
            );
          }
        },
      );
    },
  );
}
