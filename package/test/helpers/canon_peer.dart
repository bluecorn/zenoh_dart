// Compiling and driving an in-tree canon-C peer, variant-correctly.
//
// `advanced_miss_inject_test.dart` established the mechanism: a canon-C program
// that the test itself compiles against the BUILD-tree headers, spawns, and
// drives over stdin. This file generalises it on the one axis that file did not
// need — the native VARIANT — because seed #10's peer must run on both matrix
// legs, while the advanced-publisher injector is unstable-only by construction.
//
// Two things are variant-scoped and both matter:
//
//   * the INCLUDE directory — `linux-x64` defines Z_FEATURE_UNSTABLE_API and
//     Z_FEATURE_SHARED_MEMORY, `linux-x64-stable` does not, and those macros
//     change the layout of every canon options struct with a guarded member;
//   * the LIBRARY directory — the two `libzenohc.so` builds are different
//     binaries.
//
// Mixing them compiles cleanly and writes out of bounds at runtime with rc 0
// throughout, which is exactly the failure `miss_injector.c`'s header comment
// records for the other mismatch (source-tree headers vs shipped library).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'cli_process.dart';

/// Whether the loaded native is the `unstable` variant.
///
/// Read through the shim's own feature bitmask rather than from the pubspec or
/// an environment variable, so it reports what is actually loaded rather than
/// what was requested.
bool get _isUnstableVariant => ZenohFeatures.hasUnstableApi;

/// Where the ABI-correct generated headers live for the loaded variant,
/// relative to `package/`.
///
/// NOT `../extern/zenoh-c/include`. Those copies of `zenoh_opaque.h` and
/// `zenoh_configure.h` are cargo-generated, excluded by the submodule's own
/// .gitignore, and clobbered by every full build.
String get canonIncludeDir => _isUnstableVariant
    ? '../build/linux-x64/extern/zenoh-c/release/include'
    : '../build/linux-x64-stable/extern/zenoh-c/release/include';

/// Where the variant's `libzenohc.so` lives, relative to `package/`.
String get canonLibDir => _isUnstableVariant
    ? 'native/linux/x86_64/unstable'
    : 'native/linux/x86_64/stable';

/// The build recipe quoted back to whoever hits the missing-headers case.
String get _buildRecipe =>
    'Build them first, from the repo root:\n'
    '  cmake --preset ${_isUnstableVariant ? 'linux-x64' : 'linux-x64-stable'}'
    ' && cmake --build --preset '
    '${_isUnstableVariant ? 'linux-x64' : 'linux-x64-stable'} '
    '--target install\n'
    '(or the matching `-shim-only` pair when zenoh-c is already built).\n'
    'The source-tree copies under extern/zenoh-c/include are NOT a '
    'substitute — they are cargo-generated, ABI-mismatched, and compiling '
    'against them writes out of bounds.';

/// Fails the cell if [dir] is not present.
///
/// FAIL LOUD, NEVER SKIP. A toolchain-conditional skip here would silently
/// retire the only driver that exercises our receive path in isolation from
/// our own send path — and a skipped driver is indistinguishable from a
/// working one, which is the debt this harness exists to discharge rather
/// than recreate.
void requireCanonHeaders([String? dir]) {
  final target = dir ?? canonIncludeDir;
  if (!Directory(target).existsSync()) {
    fail(
      'the ABI-correct generated headers are missing at $target.\n'
      '$_buildRecipe',
    );
  }
}

/// Compiles [source] to [output] against the variant-appropriate canon build.
Future<ProcessResult> compileCanonPeer(String source, String output) {
  return Process.run('clang', [
    '-O0',
    '-g',
    source,
    '-I',
    canonIncludeDir,
    '-L',
    canonLibDir,
    '-lzenohc',
    '-Wl,-rpath,${Directory.current.path}/$canonLibDir',
    '-o',
    output,
  ]);
}

/// Compiles the peer once for the enclosing group, failing loud on either the
/// missing-headers case or a compiler error. Returns the binary's path.
Future<String> buildCanonPeer(String source, Directory tmp, String name) async {
  requireCanonHeaders();
  final path = '${tmp.path}/$name';
  final r = await compileCanonPeer(source, path);
  if (r.exitCode != 0) {
    fail('failed to compile $source\n--- clang stderr ---\n${r.stderr}');
  }
  return path;
}

/// A running canon-C peer, with line-oriented reads over its stdout.
class CanonPeer {
  CanonPeer(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
    // Never asserted on, only surfaced when a wait fails: these cells cross the
    // wire, so silence on stderr is not something to assert.
    _process.stderr.transform(utf8.decoder).listen(stderr.write);
  }

  /// Spawns [binary] with [args] and waits for its `PEER_READY` line.
  static Future<CanonPeer> start(String binary, List<String> args) async {
    final peer = CanonPeer(await Process.start(binary, args));
    await peer.waitForLine('PEER_READY');
    return peer;
  }

  final Process _process;

  /// Everything the peer has printed, in order. Quoted verbatim into any
  /// failure message, so a peer that dies mid-run diagnoses itself.
  final List<String> lines = [];

  /// Polls for the first line starting with [prefix], from [from] onwards.
  ///
  /// Fails the cell red on timeout — a peer that never answers must never hang
  /// the serial suite, which is the single sampling opportunity a close run
  /// represents.
  Future<String> waitForLine(
    String prefix, {
    int from = 0,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (var i = from; i < lines.length; i++) {
        if (lines[i].startsWith(prefix)) return lines[i];
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail(
      'the canon peer never printed a line starting with "$prefix" within '
      '$timeout\n--- peer stdout ---\n${lines.join('\n')}',
    );
  }

  void send(String command) => _process.stdin.writeln(command);

  Future<void> kill() => forceKill(_process);
}

/// Renders [bytes] as the lower-case hex the peer's command language takes.
String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The peer's `<mime>` argument for [text].
String mimeSpec(String text) => toHex(utf8.encode(text));

/// The peer's `<schema>` argument: `-` for absent, `x<hex>` for present.
String schemaSpec(String? text) =>
    text == null ? '-' : 'x${toHex(utf8.encode(text))}';
