import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// The bundled libraries, mapped to the asset name each is registered under.
///
/// libzenoh_dart.so is the C shim (loaded at runtime via
/// DynamicLibrary.open()); libzenohc.so is the zenoh-c runtime, resolved by
/// the OS linker via DT_NEEDED.
const _bundledLibraries = <String, String>{
  'libzenoh_dart.so': 'src/bindings.dart',
  'libzenohc.so': 'src/zenohc.dart',
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final variant = _variant(input.userDefines['variant']);
    final nativeDir = _nativeDir(input.packageRoot, input.config.code, variant);

    // Both libraries must land in the SAME directory: libzenoh_dart.so carries
    // RUNPATH=$ORIGIN and resolves libzenohc.so via DT_NEEDED from its own
    // directory, so staging only the shim aborts the load.
    for (final MapEntry(key: fileName, value: assetName)
        in _bundledLibraries.entries) {
      final source = nativeDir.resolve(fileName);
      final staged = input.outputDirectory.resolve(fileName);

      // Register the copy, never the source: packageRoot may be the pub cache,
      // which a hook must not write to and whose files the Flutter build system
      // will otherwise garbage-collect as its own stale outputs.
      File.fromUri(source).copySync(staged.toFilePath());

      // Re-run this hook when `cmake install` refreshes a prebuilt, so the
      // ~2s shim-only inner loop keeps reaching the bundled copy.
      output.dependencies.add(source);

      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: assetName,
          linkMode: DynamicLoadingBundled(),
          file: staged,
        ),
      );
    }
  });
}

/// The feature variant to stage, from `hooks: user_defines: <pkg>: variant:`.
///
/// Defaults to `stable` (canon) when unset. Validated so a typo fails loudly
/// here rather than silently staging a missing directory.
String _variant(Object? raw) {
  final variant = (raw as String?) ?? 'stable';
  if (variant != 'stable' && variant != 'unstable') {
    throw FormatException(
      'hooks.user_defines.<package>.variant must be "stable" or "unstable" '
      '(or omitted for stable), got "$variant"',
    );
  }
  return variant;
}

Uri _nativeDir(Uri packageRoot, CodeConfig config, String variant) {
  final os = config.targetOS;
  final arch = config.targetArchitecture;

  if (os == OS.android) {
    // Per-(ABI x variant), mirroring Linux. On Android the `unstable` variant
    // carries the unstable API but NOT shared memory (a platform capability
    // clamp — canon can't do SHM on Android either); `stable` carries neither.
    final abi = _androidAbi(arch);
    return packageRoot.resolve('native/android/$abi/$variant/');
  }
  if (os == OS.linux) {
    // x64 → x86_64 to match uname convention
    final dirName = arch == Architecture.x64 ? 'x86_64' : arch.toString();
    return packageRoot.resolve('native/linux/$dirName/$variant/');
  }
  throw UnsupportedError('Unsupported target OS: $os');
}

String _androidAbi(Architecture arch) => switch (arch) {
  Architecture.arm64 => 'arm64-v8a',
  Architecture.arm => 'armeabi-v7a',
  Architecture.x64 => 'x86_64',
  Architecture.ia32 => 'x86',
  _ => throw UnsupportedError('Unsupported Android architecture: $arch'),
};
